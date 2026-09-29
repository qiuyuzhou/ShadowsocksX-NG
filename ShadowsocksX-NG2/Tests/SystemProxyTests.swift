import XCTest

@testable import ShadowsocksX_NG2

/// System proxy mode mapping and declarative planning are pure/testable seams;
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

  func testEndpointSignatureStoreRoundTripsAndUsesProtectedAtomicFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-system-proxy-\(UUID().uuidString)", isDirectory: true)
    let fileURL = directory.appendingPathComponent("signature.json")
    defer { try? FileManager.default.removeItem(at: directory) }

    let store = FileSystemProxyEndpointSignatureStore(fileURL: fileURL)
    let signature = SystemProxyEndpointSignature(configuration: configuration)

    try store.save(signature)

    XCTAssertEqual(try store.load(), signature)
    let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
    XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
  }

  func testLegacyOwnershipMigrationKeepsOnlyOneEndpointSignatureAndDeletesSnapshots() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "ssxng-system-proxy-migration-\(UUID().uuidString)", isDirectory: true)
    let signatureURL = directory.appendingPathComponent("signature.json")
    let legacyURL = directory.appendingPathComponent("system-proxy-ownership.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let applied = try serialized(SystemProxyPropertyList.applying(configuration, to: [:]))
    let legacyRecord: [String: Any] = [
      "entries": [
        [
          "serviceID": "service-1",
          "originalConfiguration": Data("private prior config".utf8).base64EncodedString(),
          "appliedConfiguration": applied.base64EncodedString(),
        ]
      ]
    ]
    try JSONSerialization.data(withJSONObject: legacyRecord).write(to: legacyURL)
    let store = FileSystemProxyEndpointSignatureStore(
      fileURL: signatureURL, legacyOwnershipFileURL: legacyURL)

    XCTAssertEqual(try store.load(), SystemProxyEndpointSignature(configuration: configuration))
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: signatureURL.path))
    let persistedSignature = try XCTUnwrap(
      String(data: try Data(contentsOf: signatureURL), encoding: .utf8))
    XCTAssertFalse(
      persistedSignature.contains("private prior config"),
      "迁移后只留下端点签名，不保留应用前配置")
  }

  func testLegacyMigrationDiscardsAmbiguousEndpointSignatures() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "ssxng-system-proxy-migration-\(UUID().uuidString)", isDirectory: true)
    let signatureURL = directory.appendingPathComponent("signature.json")
    let legacyURL = directory.appendingPathComponent("system-proxy-ownership.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let otherConfiguration = SystemProxyConfiguration(
      socks: .init(host: "127.0.0.1", port: 2086),
      http: .init(host: "127.0.0.1", port: 2087))
    let appliedConfigurations = try [configuration, otherConfiguration].map { item in
      try serialized(SystemProxyPropertyList.applying(item, to: [:]))
    }
    let entries: [[String: Any]] = appliedConfigurations.enumerated().map { index, applied in
      [
        "serviceID": "service-\(index)",
        "originalConfiguration": NSNull(),
        "appliedConfiguration": applied.base64EncodedString(),
      ]
    }
    try JSONSerialization.data(withJSONObject: ["entries": entries]).write(to: legacyURL)
    let store = FileSystemProxyEndpointSignatureStore(
      fileURL: signatureURL, legacyOwnershipFileURL: legacyURL)

    XCTAssertNil(try store.load(), "不同服务的旧端点不确定哪个是最近一次意图")
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: signatureURL.path))
  }

  // MARK: - Declarative planner

  private let configuration = SystemProxyConfiguration(
    socks: .init(host: "127.0.0.1", port: 1086),
    http: .init(host: "127.0.0.1", port: 1087))

  private func serialized(_ dictionary: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
  }

  private func service(
    _ id: String, location: String = "location-1", configuration data: Data?
  ) -> SystemProxyServiceState {
    SystemProxyServiceState(
      identifier: SystemProxyServiceIdentifier(locationID: location, serviceID: id),
      configuration: data)
  }

  func testApplyPlannerWritesEveryActiveServiceToDesiredValues() throws {
    let applied = try serialized(SystemProxyPropertyList.applying(configuration, to: [:]))
    let foreign = try serialized(["HTTPEnable": 1, "HTTPProxy": "proxy.example"])

    let plan = try SystemProxyPlanner.makeApplyPlan(
      services: [
        service("service-1", configuration: applied),
        service("service-2", configuration: foreign),
      ], configuration: configuration)

    XCTAssertEqual(plan.writes.map(\.identifier.serviceID), ["service-2"], "等值服务零写入")
    XCTAssertEqual(plan.outcome, .written)
    let projected = try XCTUnwrap(plan.writes.first?.configuration)
    XCTAssertTrue(SystemProxyPlanner.equivalent(projected, applied))
  }

  func testCleanupPlannerClearsWholeDictionaryOnlyForMatchingEndpointSignature() throws {
    let signature = SystemProxyEndpointSignature(configuration: configuration)
    let matching = try serialized([
      "HTTPEnable": 1,
      "HTTPProxy": configuration.http.host,
      "HTTPPort": configuration.http.port,
      "HTTPSEnable": 1,
      "HTTPSProxy": configuration.http.host,
      "HTTPSPort": configuration.http.port,
      "SOCKSEnable": 1,
      "SOCKSProxy": configuration.socks.host,
      "SOCKSPort": configuration.socks.port,
      "ThirdPartyKey": "also removed",
    ])
    let wrongEndpoint = try serialized([
      "HTTPEnable": 1,
      "HTTPProxy": configuration.http.host,
      "HTTPPort": 9090,
      "HTTPSEnable": 1,
      "HTTPSProxy": configuration.http.host,
      "HTTPSPort": 9090,
      "SOCKSEnable": 1,
      "SOCKSProxy": configuration.socks.host,
      "SOCKSPort": configuration.socks.port,
    ])
    let services = [
      service("same-id", location: "location-a", configuration: matching),
      service("same-id", location: "location-b", configuration: wrongEndpoint),
    ]

    let plan = try SystemProxyPlanner.makeClearPlan(services: services, signature: signature)

    XCTAssertEqual(plan.writes.map(\.identifier), [services[0].identifier])
    XCTAssertNil(plan.writes.first?.configuration, "匹配后清除完整 Proxies 字典")
  }

  func testSignatureRequiresEnabledSOCKSHTTPAndHTTPSAtExactEndpoints() {
    let signature = SystemProxyEndpointSignature(configuration: configuration)
    let dictionary = SystemProxyPropertyList.applying(configuration, to: [:])

    XCTAssertTrue(signature.matches(dictionary))

    var disabledHTTPS = dictionary
    disabledHTTPS[SystemProxyPropertyList.httpsEnabled] = 0
    XCTAssertFalse(signature.matches(disabledHTTPS))

    var differentSOCKS = dictionary
    differentSOCKS[SystemProxyPropertyList.socksPort] = configuration.socks.port + 1
    XCTAssertFalse(signature.matches(differentSOCKS))
  }
}
