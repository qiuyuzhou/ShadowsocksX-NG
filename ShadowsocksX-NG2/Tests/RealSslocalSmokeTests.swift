import XCTest

@testable import ShadowsocksX_NG2

/// 真实 sslocal 冒烟（issue #27 验收）：wrapper 驱动 bundle 内官方 sslocal
/// v1.25.0——本地 SOCKS 端口完成监听绑定，并完成一次完整 SOCKS5 握手（方法
/// 协商 + CONNECT 请求得到按协议的应答）。远端服务器不可达只影响应答码，不
/// 影响握手本身（真实服务器功能验证属发布门槛人工检查项）。
final class RealSslocalSmokeTests: XCTestCase {
  private var workDir: URL!
  private var contractURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    contractURL = workDir.appendingPathComponent("sslocal-active.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: workDir)
    try super.tearDownWithError()
  }

  private var sslocalURL: URL {
    get throws {
      let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sslocal")
      return try XCTUnwrap(
        FileManager.default.fileExists(atPath: url.path) ? url : nil,
        "sslocal 未嵌入 app bundle（先跑 fetch-external-binaries.sh）")
    }
  }

  /// 绑定回环临时端口拿到空闲端口号后释放。
  private func grabEphemeralLoopbackPort() throws -> Int {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    try XCTUnwrap(socketFD >= 0 ? socketFD : nil, "创建 socket 失败")
    defer { close(socketFD) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_port = 0
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(bindResult, 0)
    XCTAssertEqual(listen(socketFD, 1), 0)

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(socketFD, sockaddrPointer, &length)
      }
    }
    XCTAssertEqual(nameResult, 0)
    return Int(CFSwapInt16BigToHost(boundAddress.sin_port))
  }

  private func launchWrapper(localPort: Int) throws -> Process {
    let document = SslocalRuntimeDocument(
      servers: [
        SslocalServerDocument(
          id: "smoke-server",
          remarks: "smoke",
          server: "127.0.0.1",
          serverPort: 1,  // 远端必然拒绝：只验证本地握手与 SSLOCAL 配置格式
          password: "smoke-password",
          method: "aes-256-gcm",
          plugin: nil,
          pluginOpts: nil)
      ],
      localAddress: "127.0.0.1",
      localPort: localPort,
      inboundProtocol: "socks",
      mode: "tcp_only")
    try document.jsonData().write(to: contractURL)

    let wrapperURL = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/MacOS/ShadowsocksX-NG2Agent")
    let process = Process()
    process.executableURL = wrapperURL
    var environment = ProcessInfo.processInfo.environment
    environment["SSXNG_CONTRACT_PATH"] = contractURL.path
    environment["SSXNG_SSLOCAL_PATH"] = try sslocalURL.path
    environment["SSXNG_V2_DIR"] = workDir.path
    process.environment = environment
    try process.run()
    return process
  }

  /// 对本地 SOCKS 端口做完整握手，返回 CONNECT 应答首字节（版本, 应答码）。
  private func performSocksHandshake(port: Int) throws -> (version: UInt8, reply: UInt8)? {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    try XCTUnwrap(socketFD >= 0 ? socketFD : nil, "创建 socket 失败")
    defer { close(socketFD) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_port = in_port_t(port).bigEndian
    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connectResult == 0 else { return nil }

    // 方法协商：X'05' X'01' X'00'（一个无需认证的方法）。
    let greeting: [UInt8] = [0x05, 0x01, 0x00]
    XCTAssertEqual(try greeting.withUnsafeBytes { try writeAll(socketFD, $0) }, greeting.count)
    let methodReply = try readExactly(socketFD, count: 2)
    XCTAssertEqual(
      methodReply, [0x05, 0x00], "sslocal 应选定 NO-AUTH 方法", file: #filePath, line: #line)

    // CONNECT 127.0.0.1:1。
    let request: [UInt8] = [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x01]
    _ = try request.withUnsafeBytes { try writeAll(socketFD, $0) }
    let replyHead = try readExactly(socketFD, count: 4)
    return (replyHead[0], replyHead[1])
  }

  private func writeAll(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) throws -> Int {
    var total = 0
    while total < buffer.count {
      let written = write(descriptor, buffer.baseAddress!.advanced(by: total), buffer.count - total)
      guard written > 0 else { throw NSError(domain: "smoke", code: 1) }
      total += written
    }
    return total
  }

  private func readExactly(_ descriptor: Int32, count: Int) throws -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    while bytes.count < count {
      var scratch: [UInt8] = Array(repeating: 0, count: count - bytes.count)
      let received = read(descriptor, &scratch, scratch.count)
      guard received > 0 else { throw NSError(domain: "smoke", code: 2) }
      bytes.append(contentsOf: scratch[0..<received])
    }
    return bytes
  }

  func testRealSslocalBindsSOCKSPortAndCompletesHandshake() throws {
    let port = try grabEphemeralLoopbackPort()
    let wrapper = try launchWrapper(localPort: port)

    // 端口就绪（sslocal 实际完成绑定；同时验证我们的配置格式被上游接受）。
    var reachable = false
    let deadline = Date().addingTimeInterval(15)
    while !reachable && Date() < deadline {
      reachable =
        EndpointHealthProbe.probe(host: "127.0.0.1", port: port, timeout: 1) == .reachable
      if !reachable {
        Thread.sleep(forTimeInterval: 0.2)
      }
    }
    XCTAssertTrue(reachable, "15 秒内本地 SOCKS 端口应完成监听绑定")

    // 完整 SOCKS5 握手。
    let handshake = try performSocksHandshake(port: port)
    let reply = try XCTUnwrap(handshake, "连接成功建立后应能完成握手")
    XCTAssertEqual(reply.version, 0x05, "应答版本应为 SOCKS5")
    // 远端不可达允许失败应答码；关键在于 sslocal 按协议给出 CONNECT 应答。

    // 显式停止：SIGTERM 链对真实 sslocal 同样成立。
    kill(wrapper.processIdentifier, SIGTERM)
    let exited = XCTestExpectation(description: "wrapper exits")
    DispatchQueue.global().async {
      wrapper.waitUntilExit()
      exited.fulfill()
    }
    XCTAssertEqual(
      XCTWaiter.wait(for: [exited], timeout: 10), .completed, "wrapper 应在 SIGTERM 后退出")
    XCTAssertEqual(wrapper.terminationStatus, 0, "显式停止干净退出")
  }
}
