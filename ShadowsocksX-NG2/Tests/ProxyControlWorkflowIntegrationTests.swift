import XCTest

@testable import ShadowsocksX_NG2

/// 代理控制命令矩阵（issue #47/#60）：经生产 runtime adapter 包装的真实控制器
/// 验证 agent 开关、系统代理开关与模式切换的失败分类与恢复语义原样进入
/// snapshot。全部使用 fixture 替身，不启动真实 launch agent、不写真实
/// SystemConfiguration（这些替身测试不构成真实系统写入验证）。
@MainActor
final class ProxyControlWorkflowIntegrationTests: XCTestCase {
  private var runtime: ProxyRuntimeFixture.TemporaryRuntime!
  private var catalogFileURL: URL!
  private var activationFileURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var agent: ProxyRuntimeFixture.FakeLaunchAgent!
  private var systemProxy: ProxyRuntimeFixture.FakeSystemProxy!

  override func setUpWithError() throws {
    try super.setUpWithError()
    runtime = ProxyRuntimeFixture.makeTemporaryRuntime()
    catalogFileURL = runtime.directory.appendingPathComponent("catalog.json")
    activationFileURL = runtime.directory.appendingPathComponent("activation.json")
    credentials = InMemoryCredentialStore()
    agent = ProxyRuntimeFixture.FakeLaunchAgent()
    systemProxy = ProxyRuntimeFixture.FakeSystemProxy()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: runtime.directory)
    try super.tearDownWithError()
  }

  /// 控制器、目录工作流与代理控制工作流的生产组合（同一控制器经两条缝）。
  private struct Composition {
    let catalog: CatalogWorkflow
    let control: ProxyControlWorkflow
    let controller: ProxyRuntimeController
  }

  /// 建一个含单台服务器的目录并落盘（服务器密码进内存凭据存储）。
  private func makeSeededCatalog() throws -> NodeID {
    var catalog = ConfigurationCatalog()
    let server = try ActivationFixture.addPlainServer(
      "香港 01", in: &catalog, credentials: credentials)
    try CatalogFileStore(fileURL: catalogFileURL).save(CatalogDocument(catalog: catalog))
    return server
  }

  private func makeProxies(
    probe: EndpointProbing,
    agentStatus: LaunchAgentStatus = .notRegistered,
    settingsStore: ProxySettingsStoring? = nil,
    settings: ProxySettings? = nil,
    pacProbe: PACHealthProbing = ProxyRuntimeFixture.FakePACProbe()
  ) -> Composition {
    agent.setStatus(agentStatus)
    let controller = ProxyRuntimeController(
      catalogSnapshotReader: ProxyRuntimeFixture.catalogSnapshotReader(at: catalogFileURL),
      activationFileStore: ActivationStateFileStore(fileURL: activationFileURL),
      runtimeFileStore: RuntimeFileStore(fileURL: runtime.contract),
      credentials: credentials,
      plugins: ActivationFixture.plugins,
      listenRestore: RestoredListenSettings(
        settings: ActivationFixture.listen, unreadableError: nil),
      settingsStore: settingsStore ?? InMemoryProxySettingsStore(),
      settingsRestore: RestoredProxySettings(
        settings: settings ?? ProxySettings(listen: ActivationFixture.listen),
        unreadableError: nil),
      agent: agent,
      probe: probe,
      pacProbe: pacProbe,
      systemProxy: systemProxy,
      proxyMode: .pac,
      firewallChecker: ProxyRuntimeFixture.FakeFirewallChecker(),
      firewallExecutableURLs: [URL(fileURLWithPath: "/bundle/Helpers/sslocal")],
      firewallPollIntervalNanoseconds: 1_000_000,
      sendSignal: { _, _ in 0 })
    let fileStore = CatalogFileStore(fileURL: catalogFileURL)
    let bootstrap = CatalogCommitCoordinator.bootstrap(fileStore: fileStore)
    let catalogWorkflow = makeCatalogWorkflow(
      coordinator: CatalogCommitCoordinator(
        fileStore: fileStore,
        runtime: ProxyRuntimeSyncAdapter(controller: controller),
        bootstrap: bootstrap),
      credentials: credentials,
      plugins: ActivationFixture.plugins,
      activator: controller)
    let control = ProxyControlWorkflow(
      runtime: ControllerProxyRuntimeAdapter(controller: controller),
      targetFacts: catalogWorkflow)
    return Composition(
      catalog: catalogWorkflow, control: control, controller: controller)
  }

  // MARK: - Agent 开关与首次默认

  func testAgentEnableWithoutActiveTargetListensThroughSnapshot() async throws {
    _ = try makeSeededCatalog()
    let composition = makeProxies(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))

    let snapshot = await composition.control.setAgentEnabled(true)

    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .running, isOn: true))
    XCTAssertTrue(snapshot.agentIntentEnabled, "开关意图进入 snapshot")
    XCTAssertTrue(snapshotAgentListening(composition), "空服务器监听契约已部署")
    XCTAssertTrue(systemProxy.applied.isEmpty, "系统代理意图默认关闭")
    XCTAssertEqual(snapshot.systemProxyApplication, .idle)
    XCTAssertEqual(agent.registerCount, 1)
  }

  /// 空监听判定辅助：契约存在且无服务器。
  private func snapshotAgentListening(_ composition: Composition) -> Bool {
    guard
      let data = try? Data(contentsOf: runtime.contract),
      let document = SslocalRuntimeDocument.decodeValidated(data)
    else { return false }
    return document.servers.isEmpty
  }

  func testAgentEnableConvergesToWholeRunningSnapshotWithRealCatalogFacts() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    // 目录激活走目录工作流（生产 activator 是同一控制器）；agent 开关走控制 seam。
    _ = try await composition.catalog.activate(server)
    let snapshot = await composition.control.setAgentEnabled(true)

    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .running, isOn: true))
    XCTAssertNil(snapshot.runtime.failure)
    XCTAssertTrue(snapshot.agentIntentEnabled)
    XCTAssertEqual(snapshot.proxyMode, .pac)
    XCTAssertEqual(snapshot.availableModes, [.rule, .pac, .global, .direct])
    XCTAssertEqual(snapshot.activeTarget?.pathSummary, "香港 01", "活动目标摘要来自真实目录树")
    XCTAssertEqual(snapshot.skippedInvalidServerCount, 0)
    XCTAssertTrue(
      snapshot.httpExport.copyableLine.contains("127.0.0.1:11087"),
      "HTTP 导出能力在 snapshot 中就绪")
  }

  func testUnhealthyEndpointSurfacesTypedLaunchFailureInSnapshot() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.refusing())

    _ = try await composition.catalog.activate(server)
    let snapshot = await composition.control.setAgentEnabled(true)

    XCTAssertEqual(snapshot.runtime.status, .launchFailed)
    XCTAssertFalse(snapshot.runtime.isOn)
    guard
      case .launch(.localEndpoint(let endpoint, let host, _, .refused)) = snapshot.runtime.failure
    else {
      return XCTFail("应点名本机端点失败，实际 \(String(describing: snapshot.runtime.failure))")
    }
    XCTAssertEqual(endpoint, "SOCKS")
    XCTAssertEqual(host, "127.0.0.1")
  }

  func testPendingBackgroundApprovalSurfacesTypedFactInSnapshot() async throws {
    let server = try makeSeededCatalog()
    agent.statusAfterRegister = .requiresApproval
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    _ = try await composition.catalog.activate(server)
    let snapshot = await composition.control.setAgentEnabled(true)

    XCTAssertEqual(
      snapshot.runtime,
      ProxyRuntimeFacts(
        status: .requiresApproval,
        isOn: true,
        failure: .requiresApproval))
  }

  // MARK: - 系统代理开关（issue #60）

  func testSystemProxyIntentAppliesThroughSnapshot() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    _ = try await composition.catalog.activate(server)
    _ = await composition.control.setAgentEnabled(true)
    let snapshot = await composition.control.setSystemProxyEnabled(true)

    XCTAssertTrue(snapshot.systemProxyIntentEnabled)
    XCTAssertEqual(snapshot.systemProxyApplication, .applied)
    XCTAssertEqual(snapshot.runtime.status, .running, "agent 运行状态不受系统代理影响")
    XCTAssertEqual(systemProxy.applied.count, 1)
  }

  /// 健康门禁：端点不健康时系统代理意图保持待应用（快照呈现 pending）。
  func testSystemProxyIntentStaysPendingWhenEndpointsUnhealthy() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.refusing())

    _ = try await composition.catalog.activate(server)
    _ = await composition.control.setAgentEnabled(true)
    let snapshot = await composition.control.setSystemProxyEnabled(true)

    XCTAssertTrue(snapshot.systemProxyIntentEnabled)
    XCTAssertEqual(snapshot.systemProxyApplication, .pending, "待应用进入 snapshot")
    XCTAssertEqual(snapshot.runtime.status, .launchFailed)
    XCTAssertTrue(systemProxy.applied.isEmpty, "健康门未过不写系统设置")
  }

  /// 系统代理写入失败：typed fact 进入 snapshot，agent 继续运行。
  func testSystemProxyFailureSurfacesTypedFactInSnapshot() async throws {
    let server = try makeSeededCatalog()
    systemProxy.applyError = SystemProxyError.applyFailed("denied")
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    _ = try await composition.catalog.activate(server)
    _ = await composition.control.setAgentEnabled(true)
    let snapshot = await composition.control.setSystemProxyEnabled(true)

    XCTAssertTrue(snapshot.systemProxyIntentEnabled)
    XCTAssertEqual(
      snapshot.systemProxyApplication, .failed(.operation(.applyFailed)))
    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .running, isOn: true))
  }

  /// 关闭系统代理：恢复 NG2 持有的系统设置；本地监听不停止（issue #60）。
  func testSystemProxyOffKeepsAgentRunningAndReflectsIdleInSnapshot() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    _ = try await composition.catalog.activate(server)
    _ = await composition.control.setAgentEnabled(true)
    _ = await composition.control.setSystemProxyEnabled(true)

    let snapshot = await composition.control.setSystemProxyEnabled(false)

    XCTAssertFalse(snapshot.systemProxyIntentEnabled)
    XCTAssertEqual(snapshot.systemProxyApplication, .idle)
    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .running, isOn: true))
    XCTAssertEqual(systemProxy.restoreCount, 1)
    XCTAssertEqual(agent.unregisterCount, 0, "不注销 agent")
  }

  /// 无活动目标：agent 监听，但需要出口的系统代理意图保持待应用。
  func testSystemProxyIntentStaysPendingWithoutActiveTarget() async throws {
    _ = try makeSeededCatalog()
    let composition = makeProxies(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))
    _ = await composition.control.setAgentEnabled(true)

    let snapshot = await composition.control.setSystemProxyEnabled(true)

    XCTAssertEqual(snapshot.runtime.status, .running, "agent 以空列表监听")
    XCTAssertEqual(snapshot.systemProxyApplication, .pending, "无可用出口保持待应用")
    XCTAssertTrue(systemProxy.applied.isEmpty)
    XCTAssertNil(snapshot.activeTarget)
  }

  /// 待应用意图在目标激活后自动收敛（issue #60）。目录命令后的 snapshot 更新
  /// 经主队列 hop 到达，有界等待收敛。
  func testPendingSystemProxyIntentConvergesAfterTargetActivation() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    _ = await composition.control.setAgentEnabled(true)
    let pending = await composition.control.setSystemProxyEnabled(true)
    XCTAssertEqual(pending.systemProxyApplication, .pending)

    _ = try await composition.catalog.activate(server)
    let deadline = Date().addingTimeInterval(2)
    while composition.control.snapshot.systemProxyApplication != .applied && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }

    XCTAssertEqual(composition.control.snapshot.systemProxyApplication, .applied, "激活后自动收敛")
    XCTAssertEqual(systemProxy.applied.count, 1)
  }

  // MARK: - Agent 关闭矩阵

  func testDisableReflectsClosedIntentAndKeepsModesAvailable() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    _ = try await composition.catalog.activate(server)
    _ = await composition.control.setAgentEnabled(true)

    let snapshot = await composition.control.setAgentEnabled(false)

    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .off, isOn: false))
    XCTAssertFalse(snapshot.agentIntentEnabled)
    XCTAssertNil(snapshot.runtime.failure)
    XCTAssertEqual(snapshot.availableModes, [.rule, .pac, .global, .direct], "停用后可用操作不消失")
  }

  /// 关闭 agent 且系统代理恢复失败：agent 停止，恢复失败以系统代理 typed fact
  /// 呈现（issue #60：失败归系统代理面）。
  func testAgentOffWithSystemProxyRestoreFailureSurfacesTypedFact() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true))
    _ = try await composition.catalog.activate(server)
    _ = await composition.control.setAgentEnabled(true)
    XCTAssertEqual(composition.control.snapshot.systemProxyApplication, .applied)
    systemProxy.restoreError = SystemProxyError.commitFailed("busy")

    let snapshot = await composition.control.setAgentEnabled(false)

    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .off, isOn: false))
    XCTAssertEqual(
      snapshot.systemProxyApplication, .failed(.operation(.commitFailed)),
      "恢复失败以 typed fact 呈现，不静默视为已恢复")
  }

  // MARK: - 模式命令矩阵

  func testModeSwitchWhileOffPersistsAndSnapshotConvergesWithoutRuntimeTouch() async throws {
    _ = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let composition = makeProxies(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))

    let snapshot = await composition.control.setProxyMode(.global)

    XCTAssertEqual(snapshot.proxyMode, .global)
    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .off, isOn: false))
    XCTAssertEqual(settingsStore.saved?.preferredMode, .global, "模式先持久化")
    XCTAssertTrue(systemProxy.applied.isEmpty, "agent 未运行时不触碰系统代理")
    XCTAssertEqual(systemProxy.restoreCount, 0)
  }

  func testModePersistenceFailureKeepsOldModeAndSurfacesServiceFact() async throws {
    _ = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    settingsStore.saveError = ProxySettingsStoreError.ioFailure(detail: "disk unavailable")
    let composition = makeProxies(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))

    let snapshot = await composition.control.setProxyMode(.global)

    XCTAssertEqual(snapshot.proxyMode, .pac, "持久化失败保留旧模式")
    XCTAssertEqual(
      snapshot.runtime.failure, .service(.persistence), "失败以既有 typed fact 呈现")
    XCTAssertNil(settingsStore.saved, "失败不落半程设置")
  }

  func testSameModeCommandIsNoopWithoutSettingsOrSystemProxyWrites() async throws {
    _ = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let composition = makeProxies(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))
    let before = composition.control.snapshot

    let after = await composition.control.setProxyMode(.pac)

    XCTAssertEqual(after, before, "同模式命令无副作用，snapshot 不动")
    XCTAssertNil(settingsStore.saved)
    XCTAssertTrue(systemProxy.applied.isEmpty)
    XCTAssertEqual(systemProxy.restoreCount, 0)
  }

  // MARK: - 集成级 model test（deletion 验证，story 38/39）

  /// 状态菜单的呈现面只凭 ProxyControlWorkflow 的 snapshot 与 CatalogWorkflow
  /// 的目录事实即可完整推导；本文件不要求启动 SwiftUI，也不依赖控制器字段。
  func testStatusMenuSummaryIsFullyDerivableFromWorkflowSnapshot() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    _ = try await composition.catalog.activate(server)
    _ = await composition.control.setAgentEnabled(true)
    _ = await composition.control.setSystemProxyEnabled(true)

    let summary = StatusMenuModel.summary(from: composition.control.snapshot)

    XCTAssertTrue(summary.agentIntentEnabled)
    XCTAssertTrue(summary.isOn)
    XCTAssertEqual(summary.status, "代理运行中")
    XCTAssertEqual(summary.modeLabel, "PAC")
    XCTAssertEqual(summary.targetPath, "香港 01")
    XCTAssertNil(summary.detail)
    XCTAssertTrue(summary.systemProxyIntentEnabled)
    XCTAssertEqual(summary.systemProxyStatus, "系统代理：已应用")
    XCTAssertNil(summary.systemProxyDetail)
  }

  // MARK: - HTTP 导出能力派生（生产 adapter 的唯一点）

  func testHTTPExportCapabilityDerivesSafeCopyableLineForLoopback() {
    XCTAssertEqual(
      HTTPExportCapability(listen: SslocalListenSettings()).copyableLine,
      "export http_proxy=http://127.0.0.1:11087;export https_proxy=http://127.0.0.1:11087;")
  }

  func testHTTPExportCapabilityUsesAdvertisedAddressAndPortInHostScope() {
    var listen = SslocalListenSettings()
    listen.scope = .host(advertisedAddress: "192.168.1.10")
    listen.httpPort = 8080
    XCTAssertEqual(
      HTTPExportCapability(listen: listen).copyableLine,
      "export http_proxy=http://192.168.1.10:8080;export https_proxy=http://192.168.1.10:8080;")
  }
}
