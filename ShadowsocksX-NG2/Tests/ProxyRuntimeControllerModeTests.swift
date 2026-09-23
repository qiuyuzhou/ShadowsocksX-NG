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

    await controller.setProxyEnabled(true)

    XCTAssertEqual(
      controller.runtimeFacts,
      ProxyRuntimeFacts(
        status: .activationFailed,
        isOn: false,
        failure: .activation(.noActiveTarget)))
  }

  func testRestoreUsesConfiguredExternalPACWhenItIsAvailable() {
    let url = URL(string: "https://pac.example.test/proxy.pac")!
    var restoredSettings = ProxySettings(externalPACURL: url.absoluteString)
    restoredSettings.preferredMode = .externalPAC

    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsRestore: RestoredProxySettings(settings: restoredSettings, unreadableError: nil),
      proxyMode: nil)

    XCTAssertEqual(controller.proxyMode, .externalPAC(url))
  }

  func testRestoreFallsBackToPACWhenExternalPACIsUnavailable() {
    for url in ["", "ftp://pac.example.test/proxy.pac"] {
      var restoredSettings = ProxySettings(externalPACURL: url)
      restoredSettings.preferredMode = .externalPAC

      let controller = makeController(
        probe: ProxyRuntimeFixture.FakeProbe.reachable(),
        settingsRestore: RestoredProxySettings(settings: restoredSettings, unreadableError: nil),
        proxyMode: nil)

      XCTAssertEqual(controller.proxyMode, .pac, "不可用外部 PAC 应恢复为 PAC：\(url)")
    }
  }

  func testSetProxyModePersistsConfiguredExternalPAC() async {
    let url = URL(string: "https://pac.example.test/proxy.pac")!
    let settingsStore = InMemoryProxySettingsStore()
    let settings = ProxySettings(externalPACURL: url.absoluteString)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settingsRestore: RestoredProxySettings(settings: settings, unreadableError: nil))

    await controller.setProxyMode(.externalPAC(url))

    XCTAssertEqual(controller.proxyMode, .externalPAC(url))
    XCTAssertEqual(controller.settings.preferredMode, .externalPAC)
    XCTAssertEqual(settingsStore.saved?.preferredMode, .externalPAC)
  }

  func testSetProxyModeIgnoresUnconfiguredExternalPACWithoutSideEffects() async {
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)
    let originalSettings = controller.settings
    let requestedURL = URL(string: "https://pac.example.test/proxy.pac")!

    await controller.setProxyMode(.externalPAC(requestedURL))

    XCTAssertEqual(controller.settings, originalSettings)
    XCTAssertEqual(controller.proxyMode, .pac)
    XCTAssertNil(settingsStore.saved)
    XCTAssertEqual(controller.state, .off)
    XCTAssertTrue(systemProxy.applied.isEmpty)
    XCTAssertEqual(agent.registerCount, 0)
  }

  func testSetProxyModeIgnoresExternalPACWithDifferentConfiguredURL() async {
    let configuredURL = URL(string: "https://configured.example.test/proxy.pac")!
    let requestedURL = URL(string: "https://other.example.test/proxy.pac")!
    let settingsStore = InMemoryProxySettingsStore()
    var configuredSettings = ProxySettings(externalPACURL: configuredURL.absoluteString)
    configuredSettings.preferredMode = .externalPAC
    settingsStore.saved = configuredSettings
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settingsRestore: RestoredProxySettings(settings: configuredSettings, unreadableError: nil),
      proxyMode: nil)

    await controller.setProxyMode(.externalPAC(requestedURL))

    XCTAssertEqual(controller.settings, configuredSettings)
    XCTAssertEqual(controller.proxyMode, .externalPAC(configuredURL))
    XCTAssertEqual(settingsStore.saved, configuredSettings)
    XCTAssertEqual(controller.state, .off)
    XCTAssertTrue(systemProxy.applied.isEmpty)
    XCTAssertEqual(agent.registerCount, 0)
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
    let controller = makeController(catalogSnapshotReader: bootstrap.catalogSnapshotReader)
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
    XCTAssertEqual(controller.state, .off, "该命令仅选择目标，不启动代理")
  }

  func testCoordinatorUsesProductionAdapterToClearRemovedActiveTarget() async throws {
    let server = try makeSeededCatalog()
    try ActivationStateFileStore(fileURL: activationFileURL).save(activeTargetID: server)
    let fileStore = CatalogFileStore(fileURL: catalogFileURL)
    let bootstrap = CatalogCommitCoordinator.bootstrap(fileStore: fileStore)
    let controller = makeController(catalogSnapshotReader: bootstrap.catalogSnapshotReader)
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
    catalogSnapshotReader: RuntimeCatalogSnapshotReading
  ) -> ProxyRuntimeController {
    ProxyRuntimeController(
      catalogSnapshotReader: catalogSnapshotReader,
      activationFileStore: ActivationStateFileStore(fileURL: activationFileURL),
      runtimeFileStore: RuntimeFileStore(fileURL: runtime.contract),
      credentials: credentials,
      plugins: ActivationFixture.plugins,
      listenRestore: RestoredListenSettings(
        settings: ActivationFixture.listen, unreadableError: nil),
      settingsStore: InMemoryProxySettingsStore(),
      agent: agent,
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      pacProbe: ProxyRuntimeFixture.FakePACProbe(),
      systemProxy: systemProxy,
      firewallExecutableURLs: [URL(fileURLWithPath: "/bundle/Helpers/sslocal")],
      firewallPollIntervalNanoseconds: 1_000_000,
      sendSignal: { _, _ in 0 })
  }

  private func makeSeededCatalog() throws -> NodeID {
    var catalog = ConfigurationCatalog()
    let server = try ActivationFixture.addPlainServer(
      "待删除", in: &catalog, credentials: credentials)
    try CatalogFileStore(fileURL: catalogFileURL).save(CatalogDocument(catalog: catalog))
    return server
  }
}
