import XCTest

@testable import ShadowsocksX_NG2

/// 代理控制命令矩阵（issue #47）：经生产 runtime adapter 包装的真实控制器
/// 验证启用/停用/模式切换的失败分类与恢复语义原样进入 snapshot。全部使用
/// fixture 替身，不启动真实 launch agent、不写真实 SystemConfiguration。
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
    return Composition(catalog: catalogWorkflow, control: control)
  }

  // MARK: - 启用/停用矩阵

  func testEnableWithoutActiveTargetSurfacesActivationFailureInSnapshot() async throws {
    _ = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    let snapshot = await composition.control.setProxyEnabled(true)

    XCTAssertEqual(
      snapshot.runtime,
      ProxyRuntimeFacts(
        status: .activationFailed,
        isOn: false,
        failure: .activation(.noActiveTarget)))
    XCTAssertEqual(agent.registerCount, 0, "无目标不触碰 launchd（无静默回退）")
  }

  func testEnableConvergesToWholeRunningSnapshotWithRealCatalogFacts() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    // 目录激活走目录工作流（生产 activator 是同一控制器）；代理命令走控制 seam。
    _ = try await composition.catalog.activate(server)
    let snapshot = await composition.control.setProxyEnabled(true)

    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .running, isOn: true))
    XCTAssertNil(snapshot.runtime.failure)
    XCTAssertEqual(snapshot.proxyMode, .pac)
    XCTAssertEqual(snapshot.availableModes, [.pac, .global])
    XCTAssertEqual(snapshot.activeTarget?.pathSummary, "香港 01", "活动目标摘要来自真实目录树")
    XCTAssertEqual(snapshot.skippedInvalidServerCount, 0)
    XCTAssertNotNil(snapshot.httpExport, "HTTP 入站启用时导出能力在 snapshot 中就绪")
  }

  func testUnhealthyEndpointSurfacesTypedLaunchFailureInSnapshot() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.refusing())

    _ = try await composition.catalog.activate(server)
    let snapshot = await composition.control.setProxyEnabled(true)

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
    let snapshot = await composition.control.setProxyEnabled(true)

    XCTAssertEqual(
      snapshot.runtime,
      ProxyRuntimeFacts(
        status: .requiresApproval,
        isOn: true,
        failure: .requiresApproval))
  }

  func testSystemProxyFailureSurfacesTypedFactInSnapshot() async throws {
    let server = try makeSeededCatalog()
    systemProxy.applyError = SystemProxyError.applyFailed("denied")
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    _ = try await composition.catalog.activate(server)
    let snapshot = await composition.control.setProxyEnabled(true)

    XCTAssertEqual(
      snapshot.runtime,
      ProxyRuntimeFacts(
        status: .systemProxyFailed,
        isOn: true,
        failure: .systemProxy(.operation(.applyFailed))))
  }

  func testDisableReflectsClosedIntentAndKeepsModesAvailable() async throws {
    let server = try makeSeededCatalog()
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    _ = try await composition.catalog.activate(server)
    _ = await composition.control.setProxyEnabled(true)

    let snapshot = await composition.control.setProxyEnabled(false)

    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .off, isOn: false))
    XCTAssertNil(snapshot.runtime.failure)
    XCTAssertEqual(snapshot.availableModes, [.pac, .global], "停用后可用操作不消失")
  }

  func testDisableWithSystemProxyRestoreFailureSurfacesTypedFact() async throws {
    _ = try makeSeededCatalog()
    systemProxy.restoreError = SystemProxyError.commitFailed("busy")
    let composition = makeProxies(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    let snapshot = await composition.control.setProxyEnabled(false)

    XCTAssertEqual(
      snapshot.runtime,
      ProxyRuntimeFacts(
        status: .systemProxyFailed,
        isOn: true,
        failure: .systemProxy(.operation(.commitFailed))),
      "系统代理恢复失败以既有失败语义呈现，不静默视为已停")
  }

  // MARK: - 模式命令矩阵

  func testModeSwitchWhileOffPersistsAndSnapshotConvergesWithoutRuntimeTouch() async throws {
    _ = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let composition = makeProxies(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)

    let snapshot = await composition.control.setProxyMode(.global)

    XCTAssertEqual(snapshot.proxyMode, .global)
    XCTAssertEqual(snapshot.runtime, ProxyRuntimeFacts(status: .off, isOn: false))
    XCTAssertEqual(settingsStore.saved?.preferredMode, .global, "模式先持久化")
    XCTAssertTrue(systemProxy.applied.isEmpty, "代理未运行时不触碰系统代理")
  }

  func testModePersistenceFailureKeepsOldModeAndSurfacesServiceFact() async throws {
    _ = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    settingsStore.saveError = ProxySettingsStoreError.ioFailure(detail: "disk unavailable")
    let composition = makeProxies(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)

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
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)
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
    _ = await composition.control.setProxyEnabled(true)

    let summary = StatusMenuModel.summary(from: composition.control.snapshot)

    XCTAssertTrue(summary.isOn)
    XCTAssertEqual(summary.status, "代理运行中")
    XCTAssertEqual(summary.modeLabel, "PAC")
    XCTAssertEqual(summary.targetPath, "香港 01")
    XCTAssertNil(summary.detail)
  }

  // MARK: - HTTP 导出能力派生（生产 adapter 的唯一点）

  func testHTTPExportCapabilityDerivesSafeCopyableLineForLoopback() {
    XCTAssertEqual(
      HTTPExportCapability(listen: SslocalListenSettings())?.copyableLine,
      "export http_proxy=http://127.0.0.1:11087;export https_proxy=http://127.0.0.1:11087;")
  }

  func testHTTPExportCapabilityUsesAdvertisedAddressAndPortInHostScope() {
    var listen = SslocalListenSettings()
    listen.scope = .host(advertisedAddress: "192.168.1.10")
    listen.httpPort = 8080
    XCTAssertEqual(
      HTTPExportCapability(listen: listen)?.copyableLine,
      "export http_proxy=http://192.168.1.10:8080;export https_proxy=http://192.168.1.10:8080;")
  }

  func testHTTPExportCapabilityAbsentWhenHTTPInboundDisabled() {
    var listen = SslocalListenSettings()
    listen.httpProxyEnabled = false
    XCTAssertNil(HTTPExportCapability(listen: listen))
  }
}
