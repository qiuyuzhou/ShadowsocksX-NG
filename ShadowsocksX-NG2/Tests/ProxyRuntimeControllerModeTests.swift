import XCTest

@testable import ShadowsocksX_NG2

/// Mode restoration and commands share the Domain availability policy without
/// starting a real runtime or touching host proxy settings.
@MainActor
extension ProxyRuntimeControllerTests {
  func testRuntimeFactsProjectControllerStateAtStableSeam() async {
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    XCTAssertEqual(
      controller.runtimeFacts,
      ProxyRuntimeFacts(status: .off, isOn: false))

    await controller.resyncOnLaunch()

    XCTAssertEqual(
      controller.runtimeFacts,
      ProxyRuntimeFacts(status: .running, isOn: true),
      "默认 agent 意图开启：重同步后无目标也进入空列表监听")
  }

}

/// Coordinator/controller integration for the shared committed catalog source.
@MainActor
final class CatalogRuntimeSnapshotIntegrationTests: XCTestCase {
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

  func testCommitWithoutActiveTargetFeedsLaterActivationThroughSharedSnapshot() async throws {
    let fileStore = CatalogFileStore(fileURL: catalogFileURL)
    let bootstrap = CatalogCommitCoordinator.bootstrap(fileStore: fileStore)
    let controller = makeController(
      catalogSnapshotReader: bootstrap.catalogSnapshotReader,
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))
    let coordinator = CatalogCommitCoordinator(
      fileStore: fileStore,
      runtime: ProxyRuntimeSyncAdapter(controller: controller),
      bootstrap: bootstrap)

    let server = try coordinator.commit { catalog, _ in
      try ActivationFixture.addPlainServer(
        "提交后激活", in: &catalog, credentials: credentials)
    }

    XCTAssertEqual(coordinator.syncStatus, .idle, "无目标时目录只发布，不触发运行时")
    XCTAssertNil(controller.activeTargetID)
    try await controller.activate(server)

    XCTAssertEqual(controller.activeTargetID, server, "激活读取协调器刚发布的唯一快照")
    XCTAssertEqual(controller.state, .off, "agent 意图关闭时该命令仅选择目标，不部署")
  }

  func testCoordinatorUsesProductionAdapterToClearRemovedActiveTarget() async throws {
    let server = try makeSeededCatalog()
    try ActivationStateFileStore(fileURL: activationFileURL).save(activeTargetID: server)
    let fileStore = CatalogFileStore(fileURL: catalogFileURL)
    let bootstrap = CatalogCommitCoordinator.bootstrap(fileStore: fileStore)
    let controller = makeController(
      catalogSnapshotReader: bootstrap.catalogSnapshotReader,
      probe: ProxyRuntimeFixture.FakeProbe.reachable())
    let coordinator = CatalogCommitCoordinator(
      fileStore: fileStore,
      runtime: ProxyRuntimeSyncAdapter(controller: controller),
      bootstrap: bootstrap)

    try coordinator.commit { catalog, _ in try catalog.remove(server) }

    await waitUntilRuntimeSettles(
      {
        if case .finished = coordinator.syncStatus { return true }
        return false
      }())

    guard case .finished(_, .clearedAndStopped) = coordinator.syncStatus else {
      return XCTFail("生产 adapter 应以刚提交快照清理无效目标")
    }
    XCTAssertNil(controller.activeTargetID)
    XCTAssertNil(
      try ActivationStateFileStore(fileURL: activationFileURL).loadActiveTargetID(),
      "adapter 收敛后持久化清除失效目标")
  }

  private func makeController(
    catalogSnapshotReader: RuntimeCatalogSnapshotReading,
    settings: ProxySettings? = nil,
    probe: EndpointProbing = SystemEndpointProbe()
  ) -> ProxyRuntimeController {
    let runtimeFileStore = RuntimeFileStore(fileURL: runtime.contract)
    agent.onRegister = { [runtimeFileStore] in
      guard let document = runtimeFileStore.loadDocument() else { return }
      try? runtimeFileStore.writeRuntimeReceipt(for: document, processID: 42)
    }
    return ProxyRuntimeController(
      catalogSnapshotReader: catalogSnapshotReader,
      activationFileStore: ActivationStateFileStore(fileURL: activationFileURL),
      runtimeFileStore: runtimeFileStore,
      credentials: credentials,
      plugins: ActivationFixture.plugins,
      listenRestore: RestoredListenSettings(
        settings: ActivationFixture.listen, unreadableError: nil),
      settingsStore: InMemoryProxySettingsStore(),
      settingsRestore: RestoredProxySettings(
        settings: settings ?? ProxySettings(listen: ActivationFixture.listen),
        unreadableError: nil),
      agent: agent,
      probe: probe,
      systemProxy: systemProxy,
      firewallExecutableURLs: [URL(fileURLWithPath: "/bundle/Helpers/sslocal")],
      firewallPollIntervalNanoseconds: 1_000_000,
      sendSignal: { _, _ in 0 },
      processIsAlive: { $0 == 42 })
  }

  private func makeSeededCatalog() throws -> NodeID {
    var catalog = ConfigurationCatalog()
    let server = try ActivationFixture.addPlainServer(
      "待删除", in: &catalog, credentials: credentials)
    try CatalogFileStore(fileURL: catalogFileURL).save(CatalogDocument(catalog: catalog))
    return server
  }
}
