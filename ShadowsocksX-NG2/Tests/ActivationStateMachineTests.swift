import XCTest

@testable import ShadowsocksX_NG2

/// 激活主缝测试（票 #26 验收项）：单服务器激活、组展开顺序与有效启用过滤、
/// 原子失败点名原因、组目标身份保持。重展开与清除停止见 ActivationReexpansionTests。
final class ActivationStateMachineTests: XCTestCase {
  private var machine = ActivationStateMachine()

  @discardableResult
  private func activate(
    _ target: NodeID, in catalog: ConfigurationCatalog, credentials: CredentialStoring
  ) throws -> RuntimeConfiguration {
    try ActivationFixture.activate(&machine, target, in: catalog, credentials: credentials)
  }

  // MARK: 激活

  func testActivateSingleServerSelectsItAndResolvesCredentialAtDerivationTime() throws {
    var catalog = ConfigurationCatalog()
    let passwordRef = CredentialReference(rawValue: "ref-password")
    let server = try catalog.addServer(
      ActivationFixture.plainFields(remark: "香港 01", passwordRef: passwordRef))
    let credentials = try ActivationFixture.makeCredentials([passwordRef: "SECRET-密码"])

    let configuration = try activate(server, in: catalog, credentials: credentials)

    XCTAssertEqual(machine.activeTargetID, server, "单服务器激活即单选")
    XCTAssertEqual(configuration.targetID, server)
    XCTAssertEqual(configuration.document.servers.count, 1)
    let entry = configuration.document.servers[0]
    XCTAssertEqual(entry.id, server.rawValue)
    XCTAssertEqual(entry.remarks, "香港 01")
    XCTAssertEqual(entry.server, "203.0.113.7")
    XCTAssertEqual(entry.serverPort, 8388)
    XCTAssertEqual(entry.method, "aes-256-gcm")
    XCTAssertEqual(entry.password, "SECRET-密码", "密码在派生时从凭据存储解析")
    XCTAssertNil(entry.plugin, "无插件时 plugin 字段整体省略")
    XCTAssertNil(entry.pluginOpts)
    XCTAssertEqual(configuration.document.localAddress, "127.0.0.1")
    XCTAssertEqual(configuration.document.localPort, 1086)
    XCTAssertEqual(configuration.document.inboundProtocol, "socks")
    XCTAssertEqual(configuration.document.mode, "tcp_only")
  }

  func testActivateGroupExpandsEnabledLeavesInExplicitOrderAndKeepsGroupIdentity() throws {
    var catalog = ConfigurationCatalog()
    let credentials = InMemoryCredentialStore()
    let group = try catalog.addGroup("自用")
    let first = try ActivationFixture.addPlainServer(
      "a", to: group, in: &catalog, credentials: credentials)
    let disabledLeaf = try ActivationFixture.addPlainServer(
      "b", to: group, in: &catalog, credentials: credentials)
    try catalog.setEnabled(disabledLeaf, false)
    let nested = try catalog.addGroup("嵌套", to: group)
    let deepFirst = try ActivationFixture.addPlainServer(
      "c", to: nested, in: &catalog, credentials: credentials)
    let deepDisabled = try ActivationFixture.addPlainServer(
      "d", to: nested, in: &catalog, credentials: credentials)
    try catalog.setEnabled(deepDisabled, false)
    let last = try ActivationFixture.addPlainServer(
      "e", to: group, in: &catalog, credentials: credentials)

    let configuration = try activate(group, in: catalog, credentials: credentials)

    XCTAssertEqual(machine.activeTargetID, group)
    XCTAssertEqual(
      configuration.targetID, group, "组目标保持组 UUID，不被 sslocal 实际选中的后代替换")
    XCTAssertEqual(
      configuration.document.servers.map(\.id),
      [first.rawValue, deepFirst.rawValue, last.rawValue],
      "显式子序深度优先展开，禁用子树整体排除")
  }

  func testActivateGroupInsideDisabledAncestorIsRejectedAtomically() throws {
    var catalog = ConfigurationCatalog()
    let credentials = InMemoryCredentialStore()
    let outer = try catalog.addGroup("外层")
    let inner = try catalog.addGroup("内层", to: outer)
    let leaf = try ActivationFixture.addPlainServer(
      "a", to: inner, in: &catalog, credentials: credentials)
    try activate(leaf, in: catalog, credentials: credentials)

    try catalog.setEnabled(outer, false)

    ActivationFixture.assertThrows(.targetDisabled(outer)) {
      try activate(inner, in: catalog, credentials: credentials)
    }
    XCTAssertEqual(machine.activeTargetID, leaf, "原子失败：原目标与运行状态保留")
  }

  func testActivateEmptyGroupIsRejected() throws {
    var catalog = ConfigurationCatalog()
    let credentials = InMemoryCredentialStore()
    let group = try catalog.addGroup("空组")

    ActivationFixture.assertThrows(.targetExpandsToNothing(group)) {
      try activate(group, in: catalog, credentials: credentials)
    }
    XCTAssertNil(machine.activeTargetID)
  }

  func testActivateGroupWhoseLeavesAreAllDisabledIsRejected() throws {
    var catalog = ConfigurationCatalog()
    let credentials = InMemoryCredentialStore()
    let group = try catalog.addGroup("组")
    let leaf = try ActivationFixture.addPlainServer(
      "a", to: group, in: &catalog, credentials: credentials)
    try catalog.setEnabled(leaf, false)

    ActivationFixture.assertThrows(.targetExpandsToNothing(group)) {
      try activate(group, in: catalog, credentials: credentials)
    }
  }

  func testActivateServerWithUnprovidedPluginIsRejectedNamingProgram() throws {
    var catalog = ConfigurationCatalog()
    let credentials = InMemoryCredentialStore()
    let leaf = try ActivationFixture.addPlainServer("a", in: &catalog, credentials: credentials)
    var fields = try ActivationFixture.serverFields(of: leaf, in: catalog)
    fields.pluginProgram = "kcptun"
    try catalog.updateServer(leaf, with: fields)

    ActivationFixture.assertThrows(
      .invalidLeaf(node: leaf, reason: .pluginNotProvided(program: "kcptun"))
    ) {
      try activate(leaf, in: catalog, credentials: credentials)
    }
    XCTAssertNil(machine.activeTargetID, "拒绝激活，不产生目标")
  }

  func testActivateGroupContainingUnprovidedPluginLeafIsRejectedAtomically() throws {
    var catalog = ConfigurationCatalog()
    let credentials = InMemoryCredentialStore()
    let group = try catalog.addGroup("组")
    let valid = try ActivationFixture.addPlainServer(
      "a", to: group, in: &catalog, credentials: credentials)
    let broken = try ActivationFixture.addPlainServer(
      "b", to: group, in: &catalog, credentials: credentials)
    var brokenFields = try ActivationFixture.serverFields(of: broken, in: catalog)
    brokenFields.pluginProgram = "kcptun"
    try catalog.updateServer(broken, with: brokenFields)
    try activate(valid, in: catalog, credentials: credentials)

    ActivationFixture.assertThrows(
      .invalidLeaf(node: broken, reason: .pluginNotProvided(program: "kcptun"))
    ) {
      try activate(group, in: catalog, credentials: credentials)
    }
    XCTAssertEqual(machine.activeTargetID, valid, "原子失败：原目标与运行状态保留")
  }

  func testActivateServerWithManagedPluginWritesBundlePathAndResolvesOptions() throws {
    var catalog = ConfigurationCatalog()
    let passwordRef = CredentialReference(rawValue: "ref-pw-x")
    let optionsRef = CredentialReference(rawValue: "ref-options")
    let credentials = try ActivationFixture.makeCredentials([passwordRef: "pw"])
    try credentials.save("loglevel=none", for: optionsRef)
    let leaf = try catalog.addServer(
      ServerFields(
        address: "203.0.113.7",
        port: 8388,
        encryptionMethod: "aes-256-gcm",
        passwordRef: passwordRef,
        remark: "带插件",
        pluginProgram: "v2ray-plugin",
        pluginOptionsRef: optionsRef
      ))

    let configuration = try activate(leaf, in: catalog, credentials: credentials)

    let entry = configuration.document.servers[0]
    XCTAssertEqual(entry.plugin, "/bundle/Helpers/Plugins/v2ray-plugin", "受管集提供 bundle 内路径")
    XCTAssertEqual(entry.pluginOpts, "loglevel=none", "插件参数同样派生时解析")
  }

  func testActivateUnknownTargetIsRejected() throws {
    var catalog = ConfigurationCatalog()
    let credentials = InMemoryCredentialStore()
    _ = try ActivationFixture.addPlainServer("a", in: &catalog, credentials: credentials)

    ActivationFixture.assertThrows(.targetNotFound(NodeID(rawValue: "ghost"))) {
      try activate(NodeID(rawValue: "ghost"), in: catalog, credentials: credentials)
    }
  }

  func testActivateServerWithMissingCredentialIsRejectedNamingReference() throws {
    var catalog = ConfigurationCatalog()
    let credentials = InMemoryCredentialStore()
    let missingRef = CredentialReference(rawValue: "ref-missing")
    let leaf = try catalog.addServer(
      ActivationFixture.plainFields(remark: "a", passwordRef: missingRef))

    ActivationFixture.assertThrows(
      .invalidLeaf(node: leaf, reason: .credentialUnresolved(missingRef))
    ) {
      try activate(leaf, in: catalog, credentials: credentials)
    }
  }

  func testActivateServerWithFailingCredentialReadIsRejectedNamingReference() throws {
    var catalog = ConfigurationCatalog()
    let failingRef = CredentialReference(rawValue: "ref-failing")
    let leaf = try catalog.addServer(
      ActivationFixture.plainFields(remark: "a", passwordRef: failingRef))

    ActivationFixture.assertThrows(
      .invalidLeaf(node: leaf, reason: .credentialReadFailed(failingRef))
    ) {
      try activate(leaf, in: catalog, credentials: ActivationFixture.FailingCredentialStore())
    }
  }

  func testReactivateReplacesTarget() throws {
    var catalog = ConfigurationCatalog()
    let credentials = InMemoryCredentialStore()
    let first = try ActivationFixture.addPlainServer("a", in: &catalog, credentials: credentials)
    let second = try ActivationFixture.addPlainServer("b", in: &catalog, credentials: credentials)
    try activate(first, in: catalog, credentials: credentials)

    try activate(second, in: catalog, credentials: credentials)

    XCTAssertEqual(machine.activeTargetID, second)
  }
}
