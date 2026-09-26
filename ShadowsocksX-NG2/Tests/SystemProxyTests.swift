import XCTest

@testable import ShadowsocksX_NG2

/// System proxy mode mapping and ownership persistence are pure/testable seams;
/// no test in this file writes the host's real SystemConfiguration state.
final class SystemProxyTests: XCTestCase {
  func testSupportedModesProjectTheSameLocalSOCKSTarget() throws {
    let document = ProxyRuntimeFixture.makeDocument(
      localAddress: "192.168.2.89", localPort: 2086)

    XCTAssertEqual(
      try ProxyMode.rule.systemProxyConfiguration(for: document),
      SystemProxyConfiguration(
        target: .socks(host: "127.0.0.1", port: 2086),
        exceptions: FixedLocalProxyRanges.systemProxyExceptions))
    XCTAssertEqual(
      try ProxyMode.global.systemProxyConfiguration(for: document),
      SystemProxyConfiguration(
        target: .socks(host: "127.0.0.1", port: 2086),
        exceptions: FixedLocalProxyRanges.systemProxyExceptions),
      "全局模式的系统例外使用固定本地范围，与 ACL 安全策略一致")
  }

  func testSystemConfigurationProjectionEnablesOnlySOCKS() {
    let original: [String: Any] = [
      SystemProxyPropertyList.httpEnabled: 1,
      SystemProxyPropertyList.httpsEnabled: 1,
      SystemProxyPropertyList.socksEnabled: 1,
      SystemProxyPropertyList.pacEnabled: 1,
      SystemProxyPropertyList.pacURL: "http://127.0.0.1:1089/v1/proxy.pac",
      "ExceptionsList": ["localhost"],
    ]

    let socks = SystemProxyPropertyList.applying(
      .socks(host: "127.0.0.1", port: 1086), to: original)
    XCTAssertEqual(socks[SystemProxyPropertyList.pacEnabled] as? Int, 0)
    XCTAssertNil(socks[SystemProxyPropertyList.pacURL])
    XCTAssertEqual(socks[SystemProxyPropertyList.socksEnabled] as? Int, 1)
    XCTAssertEqual(socks[SystemProxyPropertyList.socksProxy] as? String, "127.0.0.1")
    XCTAssertEqual(socks[SystemProxyPropertyList.socksPort] as? Int, 1086)
    XCTAssertEqual(socks[SystemProxyPropertyList.httpEnabled] as? Int, 0)
    XCTAssertEqual(socks[SystemProxyPropertyList.httpsEnabled] as? Int, 0)

    let ownedExceptions = SystemProxyPropertyList.applying(
      SystemProxyConfiguration(
        target: .socks(host: "127.0.0.1", port: 1086),
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
