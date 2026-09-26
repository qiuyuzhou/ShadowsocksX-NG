import Combine
import XCTest

@testable import ShadowsocksX_NG2

/// Agent 开关与系统代理开关的拆分语义（issue #60）：与既有开关用例同文件
/// 追加（Xcode 测试扫描限制），扩展持有独立用例组。
extension ProxyRuntimeControllerTests {
  func testEnableWithoutActiveTargetDeploysEmptyServerListening() async throws {
    _ = try makeSeededCatalog()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))

    await controller.setAgentEnabled(true)

    XCTAssertEqual(controller.state, .running, "无活动目标 agent 仍提供本地监听")
    XCTAssertEqual(agent.registerCount, 1, "开启意图驱动注册")
    let onDisk = try XCTUnwrap(
      RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertTrue(onDisk.servers.isEmpty, "无活动目标以空服务器列表监听")
    XCTAssertEqual(onDisk.socksPort, ActivationFixture.listen.socksPort)
    XCTAssertTrue(systemProxy.applied.isEmpty, "系统代理意图关闭，不写系统设置")
    XCTAssertEqual(controller.systemProxyState, .idle)
  }
  /// 首次运行默认语义（issue #60）：GUI 重同步即按默认意图注册并监听，系统
  /// 代理保持未接管。
  func testFirstRunResyncStartsAgentWithoutSystemProxy() async throws {
    _ = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    await controller.resyncOnLaunch()

    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(agent.registerCount, 1, "首次运行默认启动 agent")
    let onDisk = try XCTUnwrap(
      RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertTrue(onDisk.servers.isEmpty)
    XCTAssertEqual(controller.systemProxyState, .idle)
    XCTAssertTrue(systemProxy.applied.isEmpty)
  }
  /// 显式关闭 agent 的选择持久化（issue #60）：GUI 重启（全新控制器 + 恢复
  /// 快照 + 注册态残留）后仍收敛到关闭。
  func testExplicitAgentOffPersistsAcrossGUIRestart() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(false)
    XCTAssertEqual(settingsStore.saved?.agentEnabled, false, "关闭选择已持久化")

    // GUI 重启：agent 注册态残留、运行时文件残留，恢复快照携带关闭意图。
    agent.setStatus(.registered)
    try Data("stale contract".utf8).write(to: runtime.contract)
    try Data("99999".utf8).write(to: runtime.pidFile)
    let restarted = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      agentStatus: .registered,
      settingsStore: settingsStore,
      settingsRestore: RestoredProxySettings(
        settings: try XCTUnwrap(settingsStore.load()), unreadableError: nil))

    await restarted.resyncOnLaunch()

    XCTAssertEqual(restarted.state, .off, "显式关闭的选择在 GUI 重启后仍生效")
    XCTAssertEqual(agent.registerCount, 1, "重启后的关闭路径不得重新注册")
    XCTAssertEqual(agent.unregisterCount, 2, "注册态残留按停止协议再次收敛")
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.contract.path))
  }
  func testSystemProxyIntentAppliesOnlyAfterHealthGateAndExitAvailable() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    await controller.setSystemProxyEnabled(true)

    XCTAssertEqual(controller.systemProxyState, .applied)
    XCTAssertEqual(
      systemProxy.applied,
      [
        SystemProxyConfiguration(
          target: .socks(host: "127.0.0.1", port: ActivationFixture.listen.socksPort),
          exceptions: FixedLocalProxyRanges.systemProxyExceptions(
            including: ProxySettings().proxyExceptionList))
      ],
      "系统代理只在本地端点健康且存在可用出口后写入")
  }
  /// 端点不健康时系统代理意图保持待应用；条件恢复后随下次收敛自动应用，
  /// 无需重新开关系统代理（issue #60「条件恢复后自动收敛」）。
  func testSystemProxyIntentStaysPendingUntilEndpointsRecover() async throws {
    let seeded = try makeSeededCatalog()
    let probe = ProxyRuntimeFixture.FakeProbe.refusing()
    let controller = makeController(probe: probe)

    // 激活即按默认意图部署：端点持续不可达 → 启动失败（走满注入的短健康窗）。
    try await controller.activate(seeded.server)
    if case .launchFailed = controller.state {
    } else {
      XCTFail("端点不可达应呈现启动失败，实际 \(controller.state)")
    }
    await controller.setSystemProxyEnabled(true)
    XCTAssertEqual(controller.systemProxyState, .pending, "意图保留为待应用")
    XCTAssertTrue(systemProxy.applied.isEmpty, "端点不健康不得写系统代理")

    // 条件恢复：探测可达后，下一次收敛自动应用待应用意图。
    probe.setOutcomes([.reachable])
    try await controller.activate(seeded.server)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(controller.systemProxyState, .applied, "恢复后自动收敛待应用意图")
    XCTAssertEqual(systemProxy.applied.count, 1)
  }
  /// 关闭系统代理（issue #60）：只恢复 NG2 持有的系统设置；本地监听与 agent
  /// 注册态不受影响。
  func testSystemProxyOffRestoresHeldSettingsAndKeepsListening() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    await controller.setSystemProxyEnabled(true)
    XCTAssertEqual(controller.systemProxyState, .applied)

    await controller.setSystemProxyEnabled(false)

    XCTAssertEqual(controller.systemProxyState, .idle)
    XCTAssertEqual(systemProxy.restoreCount, 1)
    XCTAssertEqual(controller.state, .running, "本地监听不受系统代理开关影响")
    XCTAssertEqual(agent.unregisterCount, 0, "不注销 agent")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: runtime.contract.path), "运行时契约保留")
  }
  /// 系统代理意图持久化（issue #60）：GUI 重启后从恢复快照读回。
  func testSystemProxyIntentPersistsAcrossGUIRestart() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    await controller.setSystemProxyEnabled(true)
    XCTAssertEqual(settingsStore.saved?.systemProxyEnabled, true)

    let restarted = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      agentStatus: .registered,
      settingsStore: settingsStore,
      settingsRestore: RestoredProxySettings(
        settings: try XCTUnwrap(settingsStore.load()), unreadableError: nil))
    XCTAssertTrue(restarted.systemProxyIntentEnabled)
  }
  /// ownership 冲突（issue #60）：报告而不强制覆盖，agent 继续运行。
  func testOwnershipConflictSurfacesTypedFailureAndKeepsAgentRunning() async throws {
    let seeded = try makeSeededCatalog()
    systemProxy.applyError = SystemProxyError.ownershipConflict("external change")
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    await controller.setSystemProxyEnabled(true)

    XCTAssertEqual(
      controller.systemProxyState, .failed(.ownershipConflict), "冲突以 typed 呈现")
    XCTAssertEqual(controller.state, .running, "agent 不受系统代理失败影响")
    XCTAssertTrue(systemProxy.applied.isEmpty)
  }
  /// 关闭 agent 的次序（issue #60）：先按 ownership 规则恢复系统设置，再
  /// 注销停止监听。
  func testAgentOffRestoresSystemProxyBeforeStoppingListening() async throws {
    let seeded = try makeSeededCatalog()
    let eventLog = ProxyRuntimeEventLog()
    agent.eventLog = eventLog
    systemProxy.eventLog = eventLog
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true))
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    XCTAssertEqual(controller.systemProxyState, .applied)

    await controller.setAgentEnabled(false)

    XCTAssertEqual(
      eventLog.events,
      ["register", "apply", "restore", "unregister"],
      "先恢复持有的系统设置，再停止 agent 监听")
    XCTAssertEqual(controller.systemProxyState, .idle)
  }
  /// 无效活动目标（issue #60）：清除目标且不悄悄回退；agent 继续以空服务器
  /// 列表监听；已应用的系统代理安全撤回，意图保留待应用。
  func testInvalidTargetOnCommitClearsKeepsListeningAndWithdrawsSystemProxy() async throws {
    let seeded = try makeSeededCatalog()
    try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: runtime.pidFile)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true))
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    XCTAssertEqual(controller.systemProxyState, .applied)

    // 删除活动目标 → 重展开失败 → 清除目标，agent 继续监听。
    var catalog = try CatalogFileStore(fileURL: catalogFileURL).load().catalog
    try catalog.remove(seeded.server)
    try CatalogFileStore(fileURL: catalogFileURL).save(CatalogDocument(catalog: catalog))

    let committed = try CatalogFileStore(fileURL: catalogFileURL).load().catalog
    await controller.catalogDidCommit(snapshot: committed)

    XCTAssertNil(controller.activeTargetID)
    XCTAssertNotNil(controller.lastActivationFailure, "点名原因独立呈现")
    XCTAssertEqual(controller.state, .running, "agent 保持监听")
    XCTAssertEqual(agent.unregisterCount, 0, "不注销 agent")
    let onDisk = try XCTUnwrap(RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertTrue(onDisk.servers.isEmpty, "运行时以空服务器列表继续监听")
    XCTAssertEqual(systemProxy.restoreCount, 1, "系统代理安全撤回")
    XCTAssertEqual(controller.systemProxyState, .pending, "意图保留待应用")
  }
  func testResyncWithInvalidActiveTargetClearsAndKeepsListening() async throws {
    _ = try makeSeededCatalog()
    try Data("garbage".utf8).write(to: runtime.contract)
    let missingTarget = NodeID(rawValue: "removed-target")
    try ActivationStateFileStore(fileURL: activationFileURL).save(activeTargetID: missingTarget)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), agentStatus: .registered)

    await controller.resyncOnLaunch()

    XCTAssertEqual(controller.state, .running, "目标失效后 agent 继续监听")
    XCTAssertNil(controller.activeTargetID)
    let persisted = try ActivationStateFileStore(fileURL: activationFileURL).loadActiveTargetID()
    XCTAssertNil(persisted, "失效目标已清除")
    let onDisk = try XCTUnwrap(RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertTrue(onDisk.servers.isEmpty, "以空服务器列表继续监听")
    XCTAssertNotNil(controller.lastActivationFailure)
    XCTAssertTrue(systemProxy.applied.isEmpty, "系统代理意图关闭，不写系统设置")
  }
}

extension ProxyRuntimeControllerTests {
  /// 意图已开启时的开启命令是失败态的显式重试入口（issue #60）：无需先关再开。
  func testAgentEnableCommandRetriesConvergenceWhileIntentAlreadyOn() async throws {
    let seeded = try makeSeededCatalog()
    let probe = ProxyRuntimeFixture.FakeProbe.refusing()
    let controller = makeController(probe: probe)

    // 激活即按默认意图部署：端点不可达 → 启动失败（走满注入的短健康窗）。
    try await controller.activate(seeded.server)
    if case .launchFailed = controller.state {
    } else {
      XCTFail("端点不可达应呈现启动失败，实际 \(controller.state)")
    }

    probe.setOutcomes([.reachable])
    await controller.setAgentEnabled(true)

    XCTAssertEqual(controller.state, .running, "意图已开启时开启命令重走收敛")
    XCTAssertEqual(controller.systemProxyState, .idle)
  }
}
