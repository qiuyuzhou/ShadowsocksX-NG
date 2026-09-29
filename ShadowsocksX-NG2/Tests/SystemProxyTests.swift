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

  // MARK: - Planner 决策表（issue #70）

  private let configuration = SystemProxyConfiguration(
    socks: .init(host: "127.0.0.1", port: 1086),
    http: .init(host: "127.0.0.1", port: 1087))

  private func serialized(_ dictionary: [String: Any]) throws -> Data {
    try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
  }

  private func service(_ id: String, configuration data: Data?) -> SystemProxyServiceState {
    SystemProxyServiceState(serviceID: id, configuration: data)
  }

  func testPlannerSkipsWriteWhenOwnedValuesAlreadyEqualDesired() throws {
    let applied = try serialized(SystemProxyPropertyList.applying(configuration, to: [:]))
    let existing = SystemProxyOwnershipRecord(
      entries: [
        SystemProxyOwnershipRecord.Entry(
          serviceID: "service-1", originalConfiguration: nil, appliedConfiguration: applied)
      ])

    let plan = try SystemProxyPlanner.makePlan(
      services: [service("service-1", configuration: applied)],
      existing: existing,
      configuration: configuration)

    XCTAssertTrue(plan.writes.isEmpty, "语义等价零写入")
    XCTAssertEqual(plan.outcome, .unchanged)
    XCTAssertFalse(plan.ownershipChanged, "record 原样保留，不重写文件")
    XCTAssertEqual(plan.ownership, existing)
  }

  func testPlannerWritesWhenPortConfigurationActuallyChanges() throws {
    let applied = try serialized(SystemProxyPropertyList.applying(configuration, to: [:]))
    let existing = SystemProxyOwnershipRecord(
      entries: [
        SystemProxyOwnershipRecord.Entry(
          serviceID: "service-1", originalConfiguration: nil, appliedConfiguration: applied)
      ])
    let changed = SystemProxyConfiguration(
      socks: .init(host: "127.0.0.1", port: 2086),
      http: configuration.http,
      exceptions: configuration.exceptions)

    let plan = try SystemProxyPlanner.makePlan(
      services: [service("service-1", configuration: applied)],
      existing: existing,
      configuration: changed)

    XCTAssertEqual(plan.writes.count, 1)
    XCTAssertEqual(plan.outcome, .written)
    XCTAssertTrue(plan.ownershipChanged)
    XCTAssertNil(plan.writes[0].originalConfiguration, "original 保持首次接管时的记录")
    XCTAssertTrue(
      SystemProxyPlanner.equivalent(
        plan.writes[0].appliedConfiguration,
        try serialized(SystemProxyPropertyList.applying(changed, to: [:]))))
  }

  func testPlannerWritesOnlyDifferingServiceAmongSeveral() throws {
    let applied = try serialized(SystemProxyPropertyList.applying(configuration, to: [:]))
    let junk = try serialized(
      [
        SystemProxyPropertyList.pacEnabled: 1,
        SystemProxyPropertyList.pacURL: "http://127.0.0.1:1089/proxy.pac",
      ])
    let existing = SystemProxyOwnershipRecord(
      entries: [
        SystemProxyOwnershipRecord.Entry(
          serviceID: "service-1", originalConfiguration: nil, appliedConfiguration: applied)
      ])

    let plan = try SystemProxyPlanner.makePlan(
      services: [
        service("service-1", configuration: applied),
        service("service-2", configuration: junk),
      ],
      existing: existing,
      configuration: configuration)

    XCTAssertEqual(plan.writes.map(\.serviceID), ["service-2"], "等值 service 零写入")
    XCTAssertTrue(
      SystemProxyPlanner.equivalent(plan.writes[0].originalConfiguration, junk))
    XCTAssertEqual(
      Set(plan.ownership.entries.map(\.serviceID)), ["service-1", "service-2"])
  }

  func testPlannerAdoptsForeignChangeThatCoincidentallyEqualsDesired() throws {
    let stale = SystemProxyConfiguration(
      socks: .init(host: "127.0.0.1", port: 2086),
      http: .init(host: "127.0.0.1", port: 1087))
    let original = try serialized(["SOCKSEnable": 0])
    let existing = SystemProxyOwnershipRecord(
      entries: [
        SystemProxyOwnershipRecord.Entry(
          serviceID: "service-1",
          originalConfiguration: original,
          appliedConfiguration: try serialized(
            SystemProxyPropertyList.applying(stale, to: [:])))
      ])
    let foreign = try serialized(SystemProxyPropertyList.applying(configuration, to: [:]))

    let plan = try SystemProxyPlanner.makePlan(
      services: [service("service-1", configuration: foreign)],
      existing: existing,
      configuration: configuration)

    XCTAssertTrue(plan.writes.isEmpty, "外部改动恰好等于期望值：adopt 零写入零授权")
    XCTAssertEqual(plan.outcome, .unchanged)
    XCTAssertTrue(plan.ownershipChanged, "record 需刷新 applied")
    XCTAssertTrue(
      SystemProxyPlanner.equivalent(
        plan.ownership.entries[0].appliedConfiguration, foreign))
    XCTAssertTrue(
      SystemProxyPlanner.equivalent(plan.ownership.entries[0].originalConfiguration, original),
      "adopt 保留 original，恢复完整性不受影响")
  }

  func testPlannerStillReportsConflictWhenForeignValuesDifferFromDesired() throws {
    let applied = try serialized(SystemProxyPropertyList.applying(configuration, to: [:]))
    let existing = SystemProxyOwnershipRecord(
      entries: [
        SystemProxyOwnershipRecord.Entry(
          serviceID: "service-1", originalConfiguration: nil, appliedConfiguration: applied)
      ])
    let junk = try serialized(
      [
        SystemProxyPropertyList.pacEnabled: 1,
        SystemProxyPropertyList.pacURL: "http://127.0.0.1:1089/proxy.pac",
      ])

    XCTAssertThrowsError(
      try SystemProxyPlanner.makePlan(
        services: [service("service-1", configuration: junk)],
        existing: existing,
        configuration: configuration)
    ) { error in
      XCTAssertEqual(error as? SystemProxyError, .ownershipConflict("service-1"))
    }
  }

  func testPlannerAdoptsUnownedServiceAlreadyAtDesiredValues() throws {
    let current = try serialized(SystemProxyPropertyList.applying(configuration, to: [:]))

    let plan = try SystemProxyPlanner.makePlan(
      services: [service("service-1", configuration: current)],
      existing: nil,
      configuration: configuration)

    XCTAssertTrue(plan.writes.isEmpty, "首次接管时系统值已等于期望：免授权 adopt")
    XCTAssertEqual(plan.outcome, .unchanged)
    XCTAssertTrue(plan.ownershipChanged)
    XCTAssertEqual(plan.ownership.entries.count, 1)
    XCTAssertTrue(
      SystemProxyPlanner.equivalent(plan.ownership.entries[0].originalConfiguration, current),
      "original 记当前值，restore 语义与既有 record 丢失路径一致")
  }

  func testPlannerWritesUnownedServiceWhoseValuesDiffer() throws {
    let junk = try serialized(
      [
        SystemProxyPropertyList.pacEnabled: 1,
        SystemProxyPropertyList.pacURL: "http://127.0.0.1:1089/proxy.pac",
      ])

    let plan = try SystemProxyPlanner.makePlan(
      services: [service("service-1", configuration: junk)],
      existing: nil,
      configuration: configuration)

    XCTAssertEqual(plan.writes.count, 1)
    XCTAssertEqual(plan.outcome, .written)
    XCTAssertTrue(
      SystemProxyPlanner.equivalent(plan.writes[0].originalConfiguration, junk),
      "original 记接管前的用户配置，供 restore 归还")
  }
}
