import XCTest

@testable import ShadowsocksX_NG2

/// System proxy mode mapping and ownership persistence are pure/testable seams;
/// no test in this file writes the host's real SystemConfiguration state.
final class SystemProxyTests: XCTestCase {
  func testSupportedModesProjectTheSameLocalEndpoints() throws {
    let document = ProxyRuntimeFixture.makeDocument(
      listenerMode: .allIPv4Interfaces, localPort: 2086)

    let expected = SystemProxyConfiguration(
      socks: .init(host: "127.0.0.1", port: 2086),
      http: .init(host: "127.0.0.1", port: SslocalListenSettings.defaultHTTPPort),
      exceptions: FixedLocalProxyRanges.systemProxyExceptions)
    XCTAssertEqual(
      try ProxyMode.rule.systemProxyConfiguration(for: document),
      expected)
    XCTAssertEqual(
      try ProxyMode.global.systemProxyConfiguration(for: document),
      expected,
      "全局模式的系统例外使用固定本地范围，与 ACL 安全策略一致")
  }

  func testIPv6OnlyModeProjectsSystemProxyToIPv6Loopback() throws {
    let document = SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(listenerMode: .allIPv6Interfaces))

    let configuration = try ProxyMode.rule.systemProxyConfiguration(for: document)

    XCTAssertEqual(configuration.socks.host, "::1")
    XCTAssertEqual(configuration.http.host, "::1")
  }

  func testMissingHTTPInboundIsRejectedInsteadOfPointingAtAWildcardPort() throws {
    // 防御路径：well-formed 文档允许缺 HTTP 入站；此时不得把系统代理指向
    // 无效端口 0，而应按模式错误拒绝。
    let json = """
      {"servers":[],"locals":[{"protocol":"socks","local_address":"127.0.0.1",\
      "local_port":11086,"mode":"tcp_and_udp"}],\
      "x_shadowsocksx_ng_listen":{"listener_mode":"localhost",\
      "bind_address":"127.0.0.1"}}
      """
    let document = try XCTUnwrap(SslocalRuntimeDocument.decodeValidated(Data(json.utf8)))

    XCTAssertThrowsError(try ProxyMode.rule.systemProxyConfiguration(for: document)) { error in
      XCTAssertEqual(error as? ProxyModeError, .invalidHTTPPort(0))
    }
  }

  func testSystemConfigurationProjectionEnablesSOCKSHTTPAndHTTPS() {
    let original: [String: Any] = [
      SystemProxyPropertyList.httpEnabled: 1,
      SystemProxyPropertyList.httpsEnabled: 1,
      SystemProxyPropertyList.socksEnabled: 1,
      SystemProxyPropertyList.pacEnabled: 1,
      SystemProxyPropertyList.pacURL: "http://127.0.0.1:1089/v1/proxy.pac",
      "ExceptionsList": ["localhost"],
    ]

    let applied = SystemProxyPropertyList.applying(
      SystemProxyConfiguration(
        socks: .init(host: "127.0.0.1", port: 1086),
        http: .init(host: "127.0.0.1", port: 1087)),
      to: original)
    XCTAssertEqual(applied[SystemProxyPropertyList.pacEnabled] as? Int, 0)
    XCTAssertNil(applied[SystemProxyPropertyList.pacURL])
    XCTAssertEqual(applied[SystemProxyPropertyList.socksEnabled] as? Int, 1)
    XCTAssertEqual(applied[SystemProxyPropertyList.socksProxy] as? String, "127.0.0.1")
    XCTAssertEqual(applied[SystemProxyPropertyList.socksPort] as? Int, 1086)
    XCTAssertEqual(applied[SystemProxyPropertyList.httpEnabled] as? Int, 1)
    XCTAssertEqual(applied[SystemProxyPropertyList.httpProxy] as? String, "127.0.0.1")
    XCTAssertEqual(applied[SystemProxyPropertyList.httpPort] as? Int, 1087)
    XCTAssertEqual(applied[SystemProxyPropertyList.httpsEnabled] as? Int, 1)
    XCTAssertEqual(applied[SystemProxyPropertyList.httpsProxy] as? String, "127.0.0.1")
    XCTAssertEqual(applied[SystemProxyPropertyList.httpsPort] as? Int, 1087)

    let ownedExceptions = SystemProxyPropertyList.applying(
      SystemProxyConfiguration(
        socks: .init(host: "127.0.0.1", port: 1086),
        http: .init(host: "127.0.0.1", port: 1087),
        exceptions: ["localhost", "127.0.0.1"]),
      to: original)
    XCTAssertEqual(
      ownedExceptions[SystemProxyPropertyList.exceptionsList] as? [String],
      ["localhost", "127.0.0.1"])
  }

  func testOwnershipStoreRoundTripsAndUsesProtectedAtomicFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-system-proxy-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("ownership.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = FileSystemSystemProxyOwnershipStore(fileURL: fileURL)
    let record = SystemProxyOwnershipRecord(
      entries: [
        SystemProxyOwnershipRecord.Entry(
          serviceID: "service-1", originalConfiguration: nil, appliedConfiguration: Data([1, 2, 3]))
      ])

    try store.save(record)

    XCTAssertEqual(try store.load(), record)
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    try store.clear()
    XCTAssertNil(try store.load())
  }
}
