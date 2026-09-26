import Combine
import XCTest

@testable import ShadowsocksX_NG2

/// 自定义规则变更的完整重启与失败回滚（issue #66 AC1/AC4）。
extension ProxyRuntimeControllerTests {
  private func makeCustomRuleStore() throws -> (store: CustomRuleStore, directory: URL) {
    let directory = runtime.directory.appendingPathComponent(
      "custom-rules-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let store = CustomRuleStore(fileURL: directory.appendingPathComponent("custom-rules.json"))
    return (store, directory)
  }

  private func makeControllerWithCustomRules(
    store: CustomRuleStore,
    probe: EndpointProbing = ProxyRuntimeFixture.FakeProbe.reachable(),
    settings: ProxySettings? = nil,
    proxyMode: ProxyMode? = nil,
    launchHealthTimeoutSeconds: TimeInterval = 0.05
  ) -> ProxyRuntimeController {
    makeController(
      probe: probe,
      settingsStore: InMemoryProxySettingsStore(),
      settings: settings ?? ProxySettings(listen: ActivationFixture.listen),
      proxyMode: proxyMode,
      launchHealthTimeoutSeconds: launchHealthTimeoutSeconds,
      customRuleStore: store)
  }

  /// 规则内容变化重编译 ACL 并按完整重启路径生效。
  func testUpdateCustomRulesRecompilesACLAndRestarts() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let settings = ProxySettings(
      listen: ActivationFixture.listen,
      preferredMode: .rule,
      ruleDefaultAction: .proxyWhenUnmatched)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .rule)
    try await controller.activate(seeded.server)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(controller.proxyMode, .rule)
    let unregisterBefore = agent.unregisterCount

    let rule = CustomRule(
      action: .direct, match: try RuleMatch(domainSuffix: "internal.example"))
    let outcome = await controller.updateCustomRules([rule])

    XCTAssertEqual(outcome, .saved)
    XCTAssertEqual(try store.load(), [rule])
    XCTAssertEqual(agent.unregisterCount, unregisterBefore + 1, "ACL 变化触发完整 agent 重启")
    let document = try XCTUnwrap(RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertTrue(
      document.aclRuntime?.content.contains("||internal.example") == true,
      "自定义直连规则应进入规则模式 ACL")
  }

  /// 校验拒绝：固定本地冲突整批不落地，旧规则保持不变。
  func testUpdateCustomRulesRejectsFixedLocalConflictAndKeepsPreviousRules() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let existing = CustomRule(
      action: .direct, match: try RuleMatch(domainSuffix: "kept.example"))
    try store.save([existing])
    let settings = ProxySettings(
      listen: ActivationFixture.listen,
      preferredMode: .rule,
      ruleDefaultAction: .proxyWhenUnmatched)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .rule)
    try await controller.activate(seeded.server)

    let conflicting = CustomRule(
      action: .proxy, match: try RuleMatch(ipv4CIDR: "127.0.0.0/8"))
    let outcome = await controller.updateCustomRules([existing, conflicting])

    guard case .rejected(let rejected) = outcome else {
      return XCTFail("应拒绝固定本地冲突，实际 \(outcome)")
    }
    XCTAssertEqual(rejected.map(\.reason), [.conflictsWithFixedLocalScope])
    XCTAssertFalse(rejected[0].explanation.isEmpty)
    XCTAssertEqual(try store.load(), [existing], "拒绝时旧规则保持不变")
  }

  /// 部署失败回滚旧规则与旧运行时（issue #66 AC4）。
  func testFailedCustomRuleDeployRestoresPreviousRulesAndRuntime() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let existing = CustomRule(
      action: .direct, match: try RuleMatch(domainSuffix: "kept.example"))
    try store.save([existing])
    let settings = ProxySettings(
      listen: ActivationFixture.listen,
      preferredMode: .rule,
      ruleDefaultAction: .proxyWhenUnmatched,
      systemProxyEnabled: true)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .rule, launchHealthTimeoutSeconds: 0.05)
    try await controller.activate(seeded.server)
    XCTAssertEqual(controller.state, .running)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let previousDocument = try XCTUnwrap(runtimeStore.loadDocument())
    let previousApplicationCount = systemProxy.applied.count

    agent.onRegister = { [runtimeStore, previousDocument] in
      guard let requested = runtimeStore.loadDocument() else { return }
      // 新 ACL 实例不被接受，模拟验证失败。
      let accepted =
        requested.aclRuntime?.content.contains("new-rule.example") == true
        ? previousDocument : requested
      try? runtimeStore.writeRuntimeReceipt(for: accepted, processID: 42)
    }

    let newRule = CustomRule(
      action: .direct, match: try RuleMatch(domainSuffix: "new-rule.example"))
    let outcome = await controller.updateCustomRules([newRule])

    XCTAssertEqual(outcome, .rolledBack)
    XCTAssertEqual(try store.load(), [existing], "部署失败回滚旧规则")
    XCTAssertEqual(runtimeStore.loadDocument(), previousDocument, "回滚旧运行时")
    XCTAssertFalse(
      runtimeStore.loadDocument()?.aclRuntime?.content.contains("new-rule.example") == true)
    XCTAssertEqual(controller.state, .running, "旧运行时恢复后重新呈现健康")
    XCTAssertEqual(systemProxy.applied.count, previousApplicationCount)
    XCTAssertEqual(systemProxy.restoreCount, 0, "切换失败期间保持原系统代理应用")
  }

  /// 全局模式不加载自定义规则：保存成功但 ACL 不变、不触发重启。
  func testGlobalModePersistsCustomRulesWithoutACLRestart() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let settings = ProxySettings(
      listen: ActivationFixture.listen,
      preferredMode: .global)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .global)
    try await controller.activate(seeded.server)
    XCTAssertEqual(controller.proxyMode, .global)
    let unregisterBefore = agent.unregisterCount

    let rule = CustomRule(
      action: .direct, match: try RuleMatch(domainSuffix: "internal.example"))
    let outcome = await controller.updateCustomRules([rule])

    XCTAssertEqual(outcome, .saved)
    XCTAssertEqual(try store.load(), [rule])
    XCTAssertEqual(agent.unregisterCount, unregisterBefore, "全局模式 ACL 不含自定义规则，无需重启")
    let document = try XCTUnwrap(RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertEqual(document.aclRuntime?.summary, "global")
    XCTAssertFalse(document.aclRuntime?.content.contains("internal.example") == true)
  }

  /// 诊断摘要只含数量与内容版本（issue #66 AC5）。
  func testCustomRuleSummaryExposesCountAndVersionOnly() async throws {
    let (store, _) = try makeCustomRuleStore()
    try store.save([
      CustomRule(action: .proxy, match: try RuleMatch(domainSuffix: "secret.example"))
    ])
    let controller = makeControllerWithCustomRules(store: store)

    let summary = try XCTUnwrap(controller.readCustomRuleSummary())

    XCTAssertEqual(summary.count, 1)
    XCTAssertEqual(summary.contentVersion.count, 12)
    XCTAssertFalse(summary.contentVersion.contains("secret"))
  }
}
