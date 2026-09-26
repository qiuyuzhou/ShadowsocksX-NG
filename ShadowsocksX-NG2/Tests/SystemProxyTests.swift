import XCTest

@testable import ShadowsocksX_NG2

/// System proxy mode mapping and ownership persistence are pure/testable seams;
/// no test in this file writes the host's real SystemConfiguration state.
final class SystemProxyTests: XCTestCase {
  func testSupportedModesProduceMutuallyExclusiveSystemProxyIntent() throws {
    let document = ProxyRuntimeFixture.makeDocument(
      localAddress: "192.168.2.89", localPort: 2086, pacPort: 2089)

    XCTAssertEqual(
      try ProxyMode.pac.systemProxyConfiguration(for: document),
      SystemProxyConfiguration(
        target: .pac(URL(string: "http://192.168.2.89:2089/v1/proxy.pac")!)))
    XCTAssertEqual(
      try ProxyMode.global.systemProxyConfiguration(for: document),
      SystemProxyConfiguration(
        target: .socks(host: "127.0.0.1", port: 2086),
        exceptions: FixedLocalProxyRanges.systemProxyExceptions),
      "全局模式的系统例外使用固定本地范围，与 ACL 安全策略一致")
  }

  func testSystemConfigurationProjectionEnablesOnlyPACOrSOCKS() {
    let original: [String: Any] = [
      SystemProxyPropertyList.httpEnabled: 1,
      SystemProxyPropertyList.httpsEnabled: 1,
      SystemProxyPropertyList.socksEnabled: 1,
      SystemProxyPropertyList.pacEnabled: 0,
      "ExceptionsList": ["localhost"],
    ]

    let pac = SystemProxyPropertyList.applying(
      .pac(URL(string: "http://127.0.0.1:1089/v1/proxy.pac")!), to: original)
    XCTAssertEqual(pac[SystemProxyPropertyList.pacEnabled] as? Int, 1)
    XCTAssertEqual(pac[SystemProxyPropertyList.httpEnabled] as? Int, 0)
    XCTAssertEqual(pac[SystemProxyPropertyList.httpsEnabled] as? Int, 0)
    XCTAssertEqual(pac[SystemProxyPropertyList.socksEnabled] as? Int, 0)
    XCTAssertEqual(pac["ExceptionsList"] as? [String], ["localhost"])

    let socks = SystemProxyPropertyList.applying(
      .socks(host: "127.0.0.1", port: 1086), to: original)
    XCTAssertEqual(socks[SystemProxyPropertyList.pacEnabled] as? Int, 0)
    XCTAssertEqual(socks[SystemProxyPropertyList.socksEnabled] as? Int, 1)
    XCTAssertEqual(socks[SystemProxyPropertyList.socksProxy] as? String, "127.0.0.1")
    XCTAssertEqual(socks[SystemProxyPropertyList.socksPort] as? Int, 1086)
    XCTAssertEqual(socks[SystemProxyPropertyList.httpEnabled] as? Int, 0)
    XCTAssertEqual(socks[SystemProxyPropertyList.httpsEnabled] as? Int, 0)

    let ownedExceptions = SystemProxyPropertyList.applying(
      SystemProxyConfiguration(
        target: .pac(URL(string: "http://127.0.0.1:1089/v1/proxy.pac")!),
        exceptions: ["localhost", "127.0.0.1"]),
      to: original)
    XCTAssertEqual(
      ownedExceptions[SystemProxyPropertyList.exceptionsList] as? [String],
      ["localhost", "127.0.0.1"])
  }

  func testLocalPACPassesTargetHealthProbe() async throws {
    let port = try ProxyRuntimeFixture.unusedLoopbackPort()
    let settings = SslocalListenSettings(pacPort: port)
    let server = PACServer(configuration: settings.pac)
    try server.start()
    defer { server.stop() }

    let outcome = await SystemPACHealthProbe().probe(
      url: try XCTUnwrap(settings.pac.publicURL), timeout: 2)

    XCTAssertEqual(outcome, .reachable)
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
