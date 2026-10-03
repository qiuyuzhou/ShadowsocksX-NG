import XCTest

@testable import ShadowsocksX_NG2

final class RuleEnablementControllerTests: ProxyRuntimeControllerTests {
  override func makeDefaultRuleSnapshots() -> BuiltinRuleSnapshots {
    BuiltinRuleSnapshots(loader: ProxyRuntimeFixture.controlFlowRuleSnapshot)
  }

  func testRapidRuleSavesCoalesceIntoOneLatestACLDeployment() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let first = CustomRule(action: .direct, match: .domainExact("first-save.example"))
    let latest = CustomRule(action: .direct, match: .domainExact("latest-save.example"))
    let controller = makeControllerWithCustomRules(
      store: store,
      settings: ProxySettings(
        listen: ActivationFixture.listen, preferredMode: .rule, agentEnabled: true),
      proxyMode: .rule)
    try await controller.activate(seeded.server)
    let before = agent.registerCount
    let one = await controller.commitRuleDocument(CustomRuleDocument(rules: [first]))
    let two = await controller.commitRuleDocument(CustomRuleDocument(rules: [latest]))
    XCTAssertEqual(one.outcome, .saved)
    XCTAssertEqual(two.outcome, .saved)
    XCTAssertEqual(try store.load(), [latest])
    XCTAssertEqual(
      agent.registerCount, before, "Saving does not wait for or start deployment inline")
    await controller.ruleApplicationTask?.value
    XCTAssertEqual(agent.registerCount, before + 1)
    let content = try activeACLContent(RuntimeFileStore(fileURL: runtime.contract))
    XCTAssertTrue(content.contains("latest-save.example"))
    XCTAssertFalse(content.contains("first-save.example"))
  }

  func testSaveDuringDeploymentIsAcceptedAndLatestDocumentConvergesAfterIt() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let first = CustomRule(action: .direct, match: .domainExact("in-flight.example"))
    let latest = CustomRule(action: .direct, match: .domainExact("after-flight.example"))
    let controller = makeControllerWithCustomRules(
      store: store,
      settings: ProxySettings(
        listen: ActivationFixture.listen, preferredMode: .rule, agentEnabled: true),
      proxyMode: .rule, launchHealthTimeoutSeconds: 0.3)
    try await controller.activate(seeded.server)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let started = expectation(description: "first deployment awaiting receipt")
    let before = agent.registerCount
    var firstDocument: SslocalRuntimeDocument?
    agent.onRegister = { [agent] in
      guard let document = runtimeStore.loadDocument() else { return }
      if agent?.registerCount == before + 1 {
        firstDocument = document
        try? FileManager.default.removeItem(at: runtimeStore.runtimeStatusFileURL)
        started.fulfill()
      } else {
        try? runtimeStore.writeRuntimeReceipt(for: document, processID: 42)
      }
    }
    let one = await controller.commitRuleDocument(CustomRuleDocument(rules: [first]))
    XCTAssertEqual(one.outcome, .saved)
    await fulfillment(of: [started], timeout: 3)
    let two = await controller.commitRuleDocument(CustomRuleDocument(rules: [latest]))
    XCTAssertEqual(two.outcome, .saved)
    XCTAssertEqual(try store.load(), [latest])
    XCTAssertEqual(agent.registerCount, before + 1, "A new save cannot overlap rule deployments")
    try runtimeStore.writeRuntimeReceipt(for: XCTUnwrap(firstDocument), processID: 42)
    await controller.ruleApplicationTask?.value
    XCTAssertEqual(try store.load(), [latest])
    XCTAssertEqual(agent.registerCount, before + 2)
    let content = try activeACLContent(runtimeStore)
    XCTAssertTrue(content.contains("after-flight.example"))
    XCTAssertFalse(content.contains("in-flight.example"))
    XCTAssertEqual(controller.state, .running)
  }

  func testNewPreparationStopsRemainingActionsOfAnAwaitingRuntimeOperation() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let started = expectation(description: "new source preparation")
    let loader = PausedRuntimeRuleSource(started: started)
    defer { loader.release.signal() }
    let controller = makeControllerWithCustomRules(
      store: store,
      settings: ProxySettings(
        listen: ActivationFixture.listen, preferredMode: .global, agentEnabled: true),
      proxyMode: .global, ruleSnapshots: BuiltinRuleSnapshots(loader: { loader.load($0) }))
    try await controller.activate(seeded.server)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let previous = try XCTUnwrap(runtimeStore.loadDocument())
    try Data("42".utf8).write(to: runtimeStore.pidFileURL)
    let unregistered = expectation(description: "old operation waiting for wrapper exit")
    agent.onUnregister = { unregistered.fulfill() }
    let oldOperation = Task { await controller.execute(.stop, document: nil) }
    await fulfillment(of: [unregistered], timeout: 3)
    let newMode = Task { await controller.setProxyMode(.rule) }
    await fulfillment(of: [started], timeout: 3)
    try FileManager.default.removeItem(at: runtimeStore.pidFileURL)
    let completed = await oldOperation.value
    XCTAssertFalse(completed.succeeded)
    XCTAssertEqual(runtimeStore.loadDocument(), previous, "Stale stop must not delete the contract")
    loader.release.signal()
    await newMode.value
    XCTAssertEqual(controller.lastDocument?.aclRuntime?.summary, "rule-proxy-default")
    XCTAssertEqual(controller.state, .running)
  }

  func testSystemProxyToggleDoesNotDiscardPendingRuleModePreparation() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let started = expectation(description: "background source preparation")
    let loader = PausedRuntimeRuleSource(started: started)
    defer { loader.release.signal() }
    let controller = makeControllerWithCustomRules(
      store: store,
      settings: ProxySettings(
        listen: ActivationFixture.listen, preferredMode: .global, agentEnabled: true),
      proxyMode: .global, ruleSnapshots: BuiltinRuleSnapshots(loader: { loader.load($0) }))
    try await controller.activate(seeded.server)
    let modeSwitch = Task { await controller.setProxyMode(.rule) }
    await fulfillment(of: [started], timeout: 3)
    await controller.setSystemProxyEnabled(true)
    loader.release.signal()
    await modeSwitch.value
    XCTAssertEqual(controller.proxyMode, .rule)
    XCTAssertTrue(controller.settings.systemProxyEnabled)
    XCTAssertEqual(controller.lastDocument?.aclRuntime?.summary, "rule-proxy-default")
    XCTAssertEqual(controller.state, .running)
  }

  func testOffIntentDuringSharedSourcePreparationCannotBeOverwritten() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let started = expectation(description: "background source preparation")
    let loader = PausedRuntimeRuleSource(started: started)
    defer { loader.release.signal() }
    let snapshots = BuiltinRuleSnapshots(loader: { loader.load($0) })
    let settings = ProxySettings(
      listen: ActivationFixture.listen, preferredMode: .global, agentEnabled: true)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .global, ruleSnapshots: snapshots)
    try await controller.activate(seeded.server)
    let modeSwitch = Task { await controller.setProxyMode(.rule) }
    await fulfillment(of: [started], timeout: 3)
    let identity = RuleIdentity(action: .proxy, match: .domainExact("kept.example"))
    let ruleCommit = Task {
      await controller.commitRuleDocument(
        CustomRuleDocument(rules: [], disabledIdentities: [identity]))
    }
    // Persistence happens before the awaited source. Observe the owner, not timing.
    while controller.ruleDocuments.current?.disabledIdentities.contains(identity) != true {
      await Task.yield()
    }
    await controller.setAgentEnabled(false)
    let registrationsAfterStop = agent.registerCount
    loader.release.signal()
    await modeSwitch.value
    let result = await ruleCommit.value
    XCTAssertEqual(result.outcome, .saved)
    await controller.ruleApplicationTask?.value
    XCTAssertEqual(result.document?.disabledIdentities, [identity])
    XCTAssertEqual(try store.loadDocument().disabledIdentities, [identity])
    XCTAssertEqual(controller.state, .off)
    XCTAssertFalse(controller.settings.agentEnabled)
    XCTAssertEqual(agent.registerCount, registrationsAfterStop)
    XCTAssertNil(RuntimeFileStore(fileURL: runtime.contract).loadDocument())
  }

  func testNewModeSupersedesRulePreparationWithoutRestoringOldMode() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let started = expectation(description: "background source preparation")
    let loader = PausedRuntimeRuleSource(started: started)
    defer { loader.release.signal() }
    let controller = makeControllerWithCustomRules(
      store: store,
      settings: ProxySettings(
        listen: ActivationFixture.listen, preferredMode: .global, agentEnabled: true),
      proxyMode: .global, ruleSnapshots: BuiltinRuleSnapshots(loader: { loader.load($0) }))
    try await controller.activate(seeded.server)
    let old = Task { await controller.setProxyMode(.rule) }
    await fulfillment(of: [started], timeout: 3)
    await controller.setProxyMode(.direct)
    loader.release.signal()
    await old.value
    XCTAssertEqual(controller.proxyMode, .direct)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(
      RuntimeFileStore(fileURL: runtime.contract).loadDocument()?.aclRuntime?.summary, "direct")
  }

  func testBatchDisableRestartsOnceWithoutRestoringOmittedChinaCandidate() async throws {
    let seeded = try makeSeededCatalog()
    let (store, _) = try makeCustomRuleStore()
    let settings = ProxySettings(
      listen: ActivationFixture.listen, preferredMode: .rule,
      ruleDefaultAction: .proxyWhenUnmatched, agentEnabled: true)
    let controller = makeControllerWithCustomRules(
      store: store, settings: settings, proxyMode: .rule,
      ruleSnapshots: BuiltinRuleSnapshots(bundle: AppArtifact.bundle))
    try await controller.activate(seeded.server)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let before = agent.unregisterCount
    let cnSuffix = RuleIdentity(action: .direct, match: .domainSuffix("cn"))
    let absent = RuleIdentity(action: .direct, match: .domainExact("absent.example"))
    let outcome = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [], disabledIdentities: [cnSuffix, absent]))
    XCTAssertEqual(outcome, .saved)
    await controller.ruleApplicationTask?.value
    XCTAssertEqual(agent.unregisterCount, before + 1)
    let content = try activeACLContent(runtimeStore)
    XCTAssertFalse(content.split(separator: "\n").contains("||cn"))
    let snapshot = try BuiltinRuleCatalog.loadGeolocationCN(from: AppArtifact.bundle)
    XCTAssertGreaterThan(snapshot.lossReport.absorbedCount, 0)
    XCTAssertFalse(content.split(separator: "\n").contains("||baidu.cn"))
    let noOpBefore = agent.unregisterCount
    let unchanged = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [], disabledIdentities: [cnSuffix]))
    XCTAssertEqual(unchanged, .saved)
    await controller.ruleApplicationTask?.value
    XCTAssertEqual(agent.unregisterCount, noOpBefore, "Absent identities change only persistence")
  }

  func testOffSaveUsesOwnedDocumentAndNewSessionRejectsCorruption() async throws {
    let (store, _) = try makeCustomRuleStore()
    let controller = makeControllerWithCustomRules(
      store: store, settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))
    let identity = RuleIdentity(action: .proxy, match: .domainExact("saved.example"))
    let outcome = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [], disabledIdentities: [identity]))
    XCTAssertEqual(outcome, .saved)
    await controller.ruleApplicationTask?.value
    XCTAssertEqual(agent.registerCount, 0)
    XCTAssertEqual(try store.loadDocument().disabledIdentities, [identity])
    let broken = Data("broken".utf8)
    try broken.write(to: store.fileURL)
    let newSession = makeControllerWithCustomRules(
      store: store, settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))
    let rejected = await newSession.updateRuleDocument(CustomRuleDocument(rules: []))
    XCTAssertEqual(rejected, .persistenceFailed)
    XCTAssertEqual(try Data(contentsOf: store.fileURL), broken)
    XCTAssertEqual(agent.registerCount, 0)
  }

}

extension RuleEnablementControllerTests {
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
      launchHealthTimeoutSeconds: 0.2)
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
    XCTAssertEqual(outcome, .saved)
    await controller.ruleApplicationTask?.value
    XCTAssertEqual(try store.loadDocument().disabledIdentities, [rule.identity])
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
    let result = await controller.commitRuleDocument(
      CustomRuleDocument(rules: [rule], disabledIdentities: [rule.identity]))
    XCTAssertEqual(result.outcome, .saved)
    await controller.ruleApplicationTask?.value
    XCTAssertEqual(
      result.document, CustomRuleDocument(rules: [rule], disabledIdentities: [rule.identity]))
    XCTAssertEqual(try store.loadDocument().disabledIdentities, [rule.identity])
    XCTAssertNotNil(controller.runtimeFacts.failure)
    XCTAssertNotEqual(controller.state, .running)
  }
}

private final class PausedRuntimeRuleSource: @unchecked Sendable {
  let started: XCTestExpectation
  let release = DispatchSemaphore(value: 0)
  init(started: XCTestExpectation) { self.started = started }
  func load(_ source: RulesSource) -> RuleSnapshot {
    if source == .geolocationCN {
      started.fulfill()
      release.wait()
    }
    return rulesFixture(source)
  }
}
