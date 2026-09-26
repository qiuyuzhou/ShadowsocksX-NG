import Combine
import XCTest

@testable import ShadowsocksX_NG2

extension ProxyRuntimeControllerTests {
  func testSetProxyModePersistsTheChoiceAndARestoreRestoresIt() async throws {
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)

    await controller.setProxyMode(.global)

    XCTAssertEqual(controller.proxyMode, .global)
    XCTAssertEqual(controller.settings.preferredMode, .global)
    XCTAssertEqual(settingsStore.saved?.preferredMode, .global, "模式选择随快照持久化")

    // GUI 重启路径：恢复出的控制器不注入显式模式，从持久快照读回。
    let restored = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsRestore: RestoredProxySettings(
        settings: try XCTUnwrap(settingsStore.load()), unreadableError: nil),
      proxyMode: nil)
    XCTAssertEqual(restored.proxyMode, .global)
  }

  func testSetProxyModePersistenceFailureKeepsPreviousModeAndNamesReason() async throws {
    let settingsStore = InMemoryProxySettingsStore()
    settingsStore.saveError = FakeSettingsSaveError.system
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)

    await controller.setProxyMode(.global)

    XCTAssertEqual(controller.proxyMode, .rule, "持久化失败保留旧模式")
    XCTAssertEqual(controller.settings.preferredMode, .rule)
    guard case .serviceFailed(.persistence) = controller.state else {
      XCTFail("应点名持久化失败，实际 \(controller.state)")
      return
    }
  }

  func testDirectModeDeploysACLWithoutServerAndProjectsSOCKSProxy() async throws {
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true))

    await controller.resyncOnLaunch()
    XCTAssertEqual(controller.state, .running)
    XCTAssertTrue(systemProxy.applied.isEmpty, "规则模式没有活动目标时不得接管")
    let unregisterCount = agent.unregisterCount

    await controller.setProxyMode(.direct)

    XCTAssertEqual(controller.proxyMode, .direct)
    XCTAssertEqual(controller.settings.preferredMode, .direct)
    XCTAssertEqual(settingsStore.saved?.preferredMode, .direct)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(agent.unregisterCount, unregisterCount + 1, "ACL 变化触发完整 agent 重启")
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let document = try XCTUnwrap(runtimeStore.loadDocument())
    XCTAssertTrue(document.servers.isEmpty, "直连模式允许空服务器列表")
    XCTAssertEqual(document.aclRuntime?.summary, "direct")
    XCTAssertEqual(
      try Data(contentsOf: runtimeStore.aclFileURL),
      Data(try XCTUnwrap(document.aclRuntime).content.utf8))
    XCTAssertEqual(
      systemProxy.applied.last?.target,
      .socks(host: "127.0.0.1", port: ActivationFixture.listen.socksPort))
    XCTAssertTrue(
      Set(FixedLocalProxyRanges.systemProxyExceptions).isSubset(
        of: Set(systemProxy.applied.last?.exceptions ?? [])))
    XCTAssertEqual(controller.systemProxyState, .applied)

    let registersBeforeDisable = agent.unregisterCount
    await controller.setSystemProxyEnabled(false)
    XCTAssertEqual(controller.state, .running, "关闭系统代理不停止本地入口")
    XCTAssertEqual(agent.unregisterCount, registersBeforeDisable)
    XCTAssertEqual(controller.systemProxyState, .idle)

    let restored = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsRestore: RestoredProxySettings(
        settings: try XCTUnwrap(settingsStore.load()), unreadableError: nil),
      proxyMode: nil)
    XCTAssertEqual(restored.proxyMode, .direct, "模式选择从持久快照恢复")
  }

  func testFailedDirectInstanceRestoresOldModeRuntimeAndSystemProxy() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true),
      launchHealthTimeoutSeconds: 0.05)
    try await controller.activate(seeded.server)
    XCTAssertEqual(controller.systemProxyState, .applied)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let previousDocument = try XCTUnwrap(runtimeStore.loadDocument())
    let previousApplicationCount = systemProxy.applied.count
    var observedStates: [ProxyRuntimeController.AgentRunState] = []
    let cancellable = controller.$state.sink { observedStates.append($0) }
    defer { cancellable.cancel() }

    agent.onRegister = { [runtimeStore, previousDocument] in
      guard let requested = runtimeStore.loadDocument() else { return }
      let accepted = requested.aclRuntime == nil ? requested : previousDocument
      try? runtimeStore.writeRuntimeReceipt(for: accepted, processID: 42)
    }

    await controller.setProxyMode(.direct)

    XCTAssertTrue(observedStates.contains(.starting), "重启期间呈现短暂不可用状态")
    XCTAssertEqual(controller.proxyMode, .rule, "新实例未验证时恢复旧模式")
    XCTAssertEqual(controller.settings.preferredMode, .rule)
    XCTAssertEqual(settingsStore.saved?.preferredMode, .rule)
    XCTAssertEqual(try runtimeStore.loadDocument(), previousDocument)
    XCTAssertEqual(controller.state, .running, "旧运行时恢复后重新呈现健康")
    XCTAssertEqual(controller.systemProxyState, .applied)
    XCTAssertEqual(systemProxy.applied.count, previousApplicationCount)
    XCTAssertEqual(systemProxy.restoreCount, 0, "切换失败期间保持原系统代理应用")
  }

  /// Agent 开关持久化失败（issue #60）：保留现状并点名，不静默偏离持久化
  /// 事实（否则重启后意图被覆盖）。
  func testAgentTogglePersistenceFailureKeepsStateAndNamesReason() async throws {
    let settingsStore = InMemoryProxySettingsStore()
    settingsStore.saveError = FakeSettingsSaveError.system
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))

    await controller.setAgentEnabled(true)

    XCTAssertEqual(controller.state, .serviceFailed(.persistence))
    XCTAssertFalse(controller.agentIntentEnabled, "持久化失败不改变内存意图")
    XCTAssertEqual(agent.registerCount, 0, "意图未落地前不收敛运行时")
  }

  func testDirectReceiptIsRecheckedAfterReachableStaleListenerProbes() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let processLiveness = ProcessLivenessRecorder()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true),
      processIsAlive: { processLiveness.isAlive($0) })
    try await controller.activate(seeded.server)
    XCTAssertEqual(controller.systemProxyState, .applied)

    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let previousDocument = try XCTUnwrap(runtimeStore.loadDocument())
    let appliedCount = systemProxy.applied.count
    agent.onRegister = { [runtimeStore] in
      guard let requested = runtimeStore.loadDocument() else { return }
      // 新直连实例用一次性存活的 pid 43；其余（含回滚后的旧实例）恒活 pid 42。
      let processID: Int32 = requested.aclRuntime?.summary == "direct" ? 43 : 42
      try? runtimeStore.writeRuntimeReceipt(for: requested, processID: processID)
    }

    await controller.setProxyMode(.direct)

    XCTAssertEqual(controller.proxyMode, .rule, "探测期间新子进程退出时回滚旧模式")
    XCTAssertEqual(controller.state, .running, "旧实例应保持健康")
    XCTAssertEqual(runtimeStore.loadDocument(), previousDocument)
    XCTAssertEqual(controller.systemProxyState, .applied)
    XCTAssertEqual(systemProxy.applied.count, appliedCount, "旧系统代理保持应用")
    XCTAssertEqual(systemProxy.restoreCount, 0)
  }

  private enum FakeSettingsSaveError: Error, CustomStringConvertible {
    case system

    var description: String { "fake-save-error" }
  }
}

private final class ProcessLivenessRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var candidateChecks = 0

  func isAlive(_ pid: Int32) -> Bool {
    if pid == 42 { return true }
    guard pid == 43 else { return false }
    lock.lock()
    defer { lock.unlock() }
    candidateChecks += 1
    return candidateChecks == 1
  }
}
