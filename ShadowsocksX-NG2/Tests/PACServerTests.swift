import Darwin
import XCTest

@testable import ShadowsocksX_NG2

/// issue #28 的真实 socket 缝：请求经过 TCP 与 Network.framework listener，
/// 不直接调用 HTTP 解析器。
final class PACServerTests: XCTestCase {
  func testVersionedEndpointServesPACOverHTTP11() throws {
    let port = try ProxyRuntimeFixture.unusedLoopbackPort()
    let configuration = SslocalListenSettings(
      scope: .loopback, socksPort: 2086, httpPort: 2087,
      pacPort: port
    ).pac
    let server = PACServer(configuration: configuration)
    try server.start()
    defer { server.stop() }

    let response = try request(
      port: port,
      text: "GET /v1/proxy.pac HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")

    XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
    XCTAssertTrue(response.contains("Content-Type: application/x-ns-proxy-autoconfig\r\n"))
    XCTAssertTrue(response.contains("Cache-Control: no-store\r\n"))
    XCTAssertTrue(
      response.hasSuffix(
        "function FindProxyForURL(url, host) { return \"SOCKS5 127.0.0.1:2086; SOCKS 127.0.0.1:2086; DIRECT\"; }\n"
      ))
  }

  func testOnlyGETOnTheVersionedEndpointIsAccepted() throws {
    let port = try ProxyRuntimeFixture.unusedLoopbackPort()
    let configuration = SslocalListenSettings(
      pacPort: port
    ).pac
    let server = PACServer(configuration: configuration)
    try server.start()
    defer { server.stop() }

    let missing = try request(
      port: port,
      text: "GET /proxy.pac HTTP/1.1\r\nHost: localhost\r\n\r\n")
    let wrongMethod = try request(
      port: port,
      text: "POST /v1/proxy.pac HTTP/1.1\r\nHost: localhost\r\n\r\n")
    let missingHost = try request(
      port: port,
      text: "GET /v1/proxy.pac HTTP/1.1\r\n\r\n")
    let malformedHeader = try request(
      port: port,
      text: "GET /v1/proxy.pac HTTP/1.1\r\nHost: localhost\r\nnot-a-header\r\n\r\n")

    XCTAssertTrue(missing.hasPrefix("HTTP/1.1 404 Not Found\r\n"))
    XCTAssertTrue(wrongMethod.hasPrefix("HTTP/1.1 405 Method Not Allowed\r\n"))
    XCTAssertTrue(wrongMethod.contains("Allow: GET\r\n"))
    XCTAssertTrue(missingHost.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
    XCTAssertTrue(malformedHeader.hasPrefix("HTTP/1.1 400 Bad Request\r\n"))
  }

  func testHostScopeBindsWildcardAndPublishesTheNetworkAddress() throws {
    let port = try ProxyRuntimeFixture.unusedLoopbackPort()
    let configuration = SslocalListenSettings(
      scope: .host(advertisedAddress: "192.168.2.89"),
      socksPort: 2086,
      httpPort: 2087,
      pacPort: port
    ).pac
    let server = PACServer(configuration: configuration)
    try server.start()
    defer { server.stop() }

    let response = try request(
      port: port,
      text: "GET /v1/proxy.pac HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n")

    XCTAssertTrue(response.hasPrefix("HTTP/1.1 200 OK\r\n"))
    XCTAssertTrue(response.contains("SOCKS5 192.168.2.89:2086"))
  }

  func testStopMakesPACEndpointUnreachable() throws {
    let port = try ProxyRuntimeFixture.unusedLoopbackPort()
    let server = PACServer(
      configuration: SslocalListenSettings(pacPort: port).pac)
    try server.start()
    XCTAssertTrue(canConnect(port: port))

    server.stop()

    XCTAssertFalse(canConnect(port: port), "显式停止后 PAC listener 必须释放端口")
  }

  func testSlowIncompleteHeaderIsClosedAndDoesNotPoisonTheEndpoint() throws {
    let port = try ProxyRuntimeFixture.unusedLoopbackPort()
    let server = PACServer(
      configuration: SslocalListenSettings(pacPort: port).pac,
      requestHeaderTimeout: 0.05)
    try server.start()
    defer { server.stop() }

    let slowClient = try connectedSocket(port: port)
    defer { close(slowClient) }
    let partialRequest = Array("GET /v1/proxy.pac HTTP/1.1\r\n".utf8)
    _ = partialRequest.withUnsafeBytes { buffer in
      send(slowClient, buffer.baseAddress, buffer.count, 0)
    }
    usleep(100_000)
    var byte: UInt8 = 0
    XCTAssertLessThanOrEqual(recv(slowClient, &byte, 1, 0), 0, "慢请求必须在期限后关闭")

    let healthyResponse = try request(
      port: port,
      text: "GET /v1/proxy.pac HTTP/1.1\r\nHost: localhost\r\n\r\n")
    XCTAssertTrue(healthyResponse.hasPrefix("HTTP/1.1 200 OK\r\n"))
  }

  private func request(port: Int, text: String) throws -> String {
    let descriptor = try connectedSocket(port: port)
    defer { close(descriptor) }

    let bytes = Array(text.utf8)
    let sent = bytes.withUnsafeBytes { buffer in
      send(descriptor, buffer.baseAddress, buffer.count, 0)
    }
    XCTAssertEqual(sent, bytes.count)

    var response = Data()
    var buffer = [UInt8](repeating: 0, count: 4096)
    while true {
      let count = recv(descriptor, &buffer, buffer.count, 0)
      if count <= 0 { break }
      response.append(buffer, count: count)
    }
    return try XCTUnwrap(String(data: response, encoding: .utf8))
  }

  private func canConnect(port: Int) -> Bool {
    guard let descriptor = try? connectedSocket(port: port) else { return false }
    close(descriptor)
    return true
  }

  private func connectedSocket(port: Int) throws -> Int32 {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }

    var timeout = timeval(tv_sec: 2, tv_usec: 0)
    setsockopt(
      descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
      socklen_t(MemoryLayout<timeval>.size))
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = CFSwapInt16HostToBig(UInt16(port))
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else {
      let code = POSIXErrorCode(rawValue: errno) ?? .ECONNREFUSED
      close(descriptor)
      throw POSIXError(code)
    }
    return descriptor
  }
}
