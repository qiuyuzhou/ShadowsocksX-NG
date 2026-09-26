import Combine
import XCTest

@testable import ShadowsocksX_NG2

extension ProxyRuntimeControllerTests {
  // MARK: GUI 重启重同步（D5）

  func testResyncWithRegisteredAgentAndMatchingContractSkipsRewrite() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let enabledSettings = ProxySettings(listen: ActivationFixture.listen, agentEnabled: true)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), agentStatus: .notRegistered,
      settingsStore: settingsStore, settings: enabledSettings)
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    XCTAssertTrue(agent.registerCount >= 1)
    let contractMtime =
      try FileManager.default.attributesOfItem(
        atPath: runtime.contract.path
      )[.modificationDate] as? Date

    // 模拟 GUI 重启：全新控制器，agent 已注册、wrapper pid 存活（本测试进程）。
    try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: runtime.pidFile)
    let restarted = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), agentStatus: .registered,
      settingsStore: settingsStore, settings: enabledSettings)

    await restarted.resyncOnLaunch()

    XCTAssertEqual(restarted.state, .running)
    XCTAssertEqual(agent.registerCount, 1, "已注册不再重复注册")
    let afterResyncMtime =
      try FileManager.default.attributesOfItem(
        atPath: runtime.contract.path
      )[.modificationDate] as? Date
    XCTAssertEqual(contractMtime, afterResyncMtime, "相同契约内容跳过写入（幂等）")
    XCTAssertTrue(
      signals.signalsSent.filter { $0.signal != 0 }.isEmpty,
      "内容一致不需要 reload 信号")
  }

  func testLegacyImportBoundaryStopsRuntimeWithoutRestoringSystemProxy() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    var importedSettings = ProxySettings()
    importedSettings.preferredMode = .global
    settingsStore.saved = importedSettings
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      systemProxy: systemProxy)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    XCTAssertEqual(controller.state, .running)

    await controller.legacyImportDidCommit()

    XCTAssertEqual(controller.state, .off)
    XCTAssertEqual(controller.settings, importedSettings)
    XCTAssertEqual(controller.activeTargetID, seeded.server)
    XCTAssertEqual(systemProxy.restoreCount, 0, "Legacy 导入不能写入或恢复系统代理")
    XCTAssertTrue(systemProxy.applied.isEmpty, "导入边界不应重新应用系统代理")
  }

  /// 偏好重置不触碰 Agent switch，也不停掉正在运行的 Agent（ADR-0011 连带）；
  /// 系统代理意图被重置为 off 时归还已应用设置，Agent 仍开则收敛到出厂运行时。
  func testResetPreferencesKeepsAgentChoiceAndDoesNotStopAgent() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(
        listen: ActivationFixture.listen, agentEnabled: true, systemProxyEnabled: true))
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(controller.systemProxyState, .applied)
    // 夹具约定的存活 wrapper pid：收敛路径才走 signalReload 而不是重注册。
    try Data("42".utf8).write(to: runtime.pidFile)
    let unregisterBefore = agent.unregisterCount

    let outcome = try await controller.resetPreferences()

    XCTAssertEqual(controller.settings.agentEnabled, true, "Agent switch 不受偏好重置影响")
    XCTAssertEqual(settingsStore.saved?.agentEnabled, true)
    XCTAssertFalse(controller.settings.systemProxyEnabled, "系统代理意图回到出厂 off")
    XCTAssertEqual(systemProxy.restoreCount, 1, "已应用的系统代理设置被归还")
    XCTAssertEqual(agent.unregisterCount, unregisterBefore, "重置不停止 Agent")
    XCTAssertEqual(controller.state, .running, "保留的 Agent 收敛到出厂运行时")
    XCTAssertNotEqual(outcome, .stopped, "重置不是停止协议")
  }

  func testUpdatingSettingsPersistsAndReactivatesTheRuntimeContract() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(
        listen: ActivationFixture.listen, agentEnabled: true, systemProxyEnabled: true))

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    var next = controller.settings
    next.timeoutSeconds = 120
    next.verboseLogging = true
    next.proxyExceptions = "localhost, 127.0.0.1"
    try await controller.updateSettings(next)

    let document = try XCTUnwrap(RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertEqual(controller.settings, next)
    XCTAssertEqual(settingsStore.saved, next)
    XCTAssertEqual(document.timeout, 120)
    XCTAssertTrue(document.listen.verbose)
    XCTAssertEqual(
      systemProxy.applied.last?.exceptions,
      FixedLocalProxyRanges.systemProxyExceptions(including: ["localhost", "127.0.0.1"]),
      "系统代理意图开启时随设置更新重新应用")
  }
}
