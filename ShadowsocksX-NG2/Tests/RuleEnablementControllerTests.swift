import XCTest

@testable import ShadowsocksX_NG2

extension ProxyRuntimeControllerTests {
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
    XCTAssertFalse(completed)
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
    XCTAssertEqual(result.outcome, .runtimeChanged(rulesRestored: false))
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
      store: store, settings: settings, proxyMode: .rule)
    try await controller.activate(seeded.server)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let before = agent.unregisterCount
    let cnSuffix = RuleIdentity(action: .direct, match: .domainSuffix("cn"))
    let absent = RuleIdentity(action: .direct, match: .domainExact("absent.example"))
    let outcome = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [], disabledIdentities: [cnSuffix, absent]))
    XCTAssertEqual(outcome, .applied)
    XCTAssertEqual(agent.unregisterCount, before + 1)
    let content = try activeACLContent(runtimeStore)
    XCTAssertFalse(content.split(separator: "\n").contains("||cn"))
    let snapshot = try BuiltinRuleCatalog.loadGeolocationCN(from: AppArtifact.bundle)
    XCTAssertGreaterThan(snapshot.lossReport.absorbedCount, 0)
    XCTAssertFalse(content.split(separator: "\n").contains("||baidu.cn"))
    let noOpBefore = agent.unregisterCount
    let unchanged = await controller.updateRuleDocument(
      CustomRuleDocument(rules: [], disabledIdentities: [cnSuffix]))
    XCTAssertEqual(unchanged, .runtimeUnchanged)
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
    let result = await controller.commitRuleDocument(
      CustomRuleDocument(rules: [rule], disabledIdentities: [rule.identity]))
    guard case .recoveryFailed(let detail, let rulesRestored) = result.outcome else {
      return XCTFail("Expected actual recovery failure, got \(result)")
    }
    XCTAssertTrue(rulesRestored)
    XCTAssertEqual(result.document, CustomRuleDocument(rules: [rule]))
    XCTAssertFalse(detail.isEmpty)
    XCTAssertEqual(try store.loadDocument().disabledIdentities, [])
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
