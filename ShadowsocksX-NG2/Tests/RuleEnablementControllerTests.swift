import XCTest

@testable import ShadowsocksX_NG2

extension ProxyRuntimeControllerTests {
  func testBatchDisableRestartsOnceAndRestoresAbsorbedChinaCandidate() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let settings = ProxySettings(
      listen: ActivationFixture.listen, preferredMode: .rule,
      ruleDefaultAction: .proxyWhenUnmatched, agentEnabled: true)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .rule)
    try await controller.activate(seeded.server)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let before = agent.unregisterCount
    let cn = RuleIdentity(action: .direct, match: .domainSuffix("cn"))
    let absent = RuleIdentity(action: .direct, match: .domainExact("absent.example"))
    let outcome = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [], disabledIdentities: [cn, absent]))
    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(agent.unregisterCount, before + 1)
    let content = try activeACLContent(runtimeStore)
    XCTAssertFalse(content.split(separator: "\n").contains("||cn"))
    let snapshot = try BuiltinRuleCatalog.loadGeolocationCN(from: AppArtifact.bundle)
    let narrow = try XCTUnwrap(snapshot.absorbed.first)
    XCTAssertTrue(content.contains(narrow.aclLine))
    let noOpBefore = agent.unregisterCount
    let unchanged = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [], disabledIdentities: [cn]))
    XCTAssertEqual(unchanged, .runtimeUnchanged)
    XCTAssertEqual(agent.unregisterCount, noOpBefore, "Absent identities change only persistence")
  }

  func testDisablingGFWBlockersRestoresPreservedExpressibleException() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let settings = ProxySettings(
      listen: ActivationFixture.listen, preferredMode: .rule,
      ruleDefaultAction: .directWhenUnmatched, agentEnabled: true)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .rule)
    try await controller.activate(seeded.server)
    let snapshot = try BuiltinRuleCatalog.loadGFWList(from: AppArtifact.bundle)
    let exception = try XCTUnwrap(snapshot.absorbed.first)
    let blockers = Set(
      (snapshot.rules + snapshot.absorbed).filter {
        $0.action == .proxy && RuleCoverage.domainCovers($0.match, exception.match)
      }.map(\.identity))
    XCTAssertFalse(blockers.isEmpty)
    let before = agent.unregisterCount
    let outcome = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [], disabledIdentities: blockers))
    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(agent.unregisterCount, before + 1)
    let candidates = try controller.ruleModeCandidateRules()
    XCTAssertTrue(
      candidates.contains {
        $0.action == .direct && RuleCoverage.domainCovers($0.match, exception.match)
      })
  }

  func testDisableWhileOffPersistsWithoutStartingAndCorruptDocumentIsPreserved() async throws {
    let (store, _) = try makeCustomRuleStore()
    let controller = makeControllerWithCustomRules(
      store: store, settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))
    let identity = RuleIdentity(action: .proxy, match: .domainExact("saved.example"))
    let outcome = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [], disabledIdentities: [identity]))
    XCTAssertEqual(outcome, .saved)
    XCTAssertEqual(agent.registerCount, 0)
    XCTAssertEqual(try store.loadDocument().disabledIdentities, [identity])
    let broken = Data("broken".utf8)
    try broken.write(to: store.fileURL)
    let rejected = await controller.updateRuleDocument(CustomRuleDocument(rules: []))
    XCTAssertEqual(rejected, .persistenceFailed)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), broken)
    XCTAssertEqual(agent.registerCount, 0)
  }

  func testAgentOffDuringRecoveryCannotBeOverwrittenByOldRuleTransaction() async throws {
    try await interruptRuleRecovery(switchMode: false)
  }

  func testModeSwitchDuringRecoveryCannotBeOverwrittenByOldRuleTransaction() async throws {
    try await interruptRuleRecovery(switchMode: true)
  }

  private func interruptRuleRecovery(switchMode: Bool) async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let rule = CustomRule(action: .direct, match: .domainExact("kept.example"))
    try store.save([rule])
    let settings = ProxySettings(
      listen: ActivationFixture.listen, preferredMode: .rule,
      ruleDefaultAction: .proxyWhenUnmatched, agentEnabled: true)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .rule,
      launchHealthTimeoutSeconds: 1)
    try await controller.activate(seeded.server)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let recoveryStarted = expectation(description: "recovery awaiting health")
    let initialRegistrations = agent.registerCount
    agent.onRegister = { [agent] in
      if agent?.registerCount == initialRegistrations + 2 {
        recoveryStarted.fulfill()
      }
      if (agent?.registerCount ?? 0) <= initialRegistrations + 2 {
        try? FileManager.default.removeItem(at: runtimeStore.runtimeStatusFileURL)
      } else if let document = runtimeStore.loadDocument() {
        try? runtimeStore.writeRuntimeReceipt(for: document, processID: 42)
      }
    }
    let pending = Task {
      await controller.updateRuleDocument(
        CustomRuleDocument(
          rules: [rule],
          disabledIdentities: [rule.identity]))
    }
    await fulfillment(of: [recoveryStarted], timeout: 5)
    if switchMode {
      await controller.setProxyMode(.global)
    } else {
      await controller.setAgentEnabled(false)
    }
    let registrations = agent.registerCount
    let outcome = await pending.value
    guard case .runtimeChanged(let rulesRestored) = outcome else {
      return XCTFail("Interrupted recovery must not report success: \(outcome)")
    }
    XCTAssertTrue(rulesRestored)
    XCTAssertEqual(agent.registerCount, registrations)
    if switchMode {
      XCTAssertEqual(controller.proxyMode, .global)
      XCTAssertEqual(runtimeStore.loadDocument()?.aclRuntime?.summary, "global")
    } else {
      XCTAssertFalse(controller.settings.agentEnabled)
      XCTAssertEqual(controller.state, .off)
      XCTAssertNil(runtimeStore.loadDocument())
    }
  }

  func testFailedDisableAndFailedRuntimeRecoveryReportsFailure() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let rule = CustomRule(action: .direct, match: .domainExact("kept.example"))
    try store.save([rule])
    let settings = ProxySettings(
      listen: ActivationFixture.listen, preferredMode: .rule,
      ruleDefaultAction: .proxyWhenUnmatched, agentEnabled: true)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .rule)
    try await controller.activate(seeded.server)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    agent.onRegister = {
      try? FileManager.default.removeItem(at: runtimeStore.runtimeStatusFileURL)
    }
    let result = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [rule], disabledIdentities: [rule.identity]))
    guard case .recoveryFailed(let detail, let rulesRestored) = result else {
      return XCTFail("Expected actual recovery failure, got \(result)")
    }
    XCTAssertTrue(rulesRestored)
    XCTAssertFalse(detail.isEmpty)
    XCTAssertEqual(try store.loadDocument().disabledIdentities, [])
    XCTAssertNotEqual(controller.state, .running)
  }
}
