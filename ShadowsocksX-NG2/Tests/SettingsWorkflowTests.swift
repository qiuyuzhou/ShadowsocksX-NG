import XCTest

@testable import ShadowsocksX_NG2

/// 设置工作流与真实 `ProxyRuntimeController` 的提交路径集成（issue #44）：
/// 界面投影与命令面已由 `SettingsWorkflowInterfaceTests` 用 fake 写入缝覆盖；
/// 本文件保留确需端到端的场景，证明窄缝两端与运行时控制器的提交事务对齐。
@MainActor
final class SettingsWorkflowTests: XCTestCase {
  private var runtime: ProxyRuntimeFixture.TemporaryRuntime!
  private var catalogFileURL: URL!
  private var activationFileURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var agent: ProxyRuntimeFixture.FakeLaunchAgent!
  private var systemProxy: ProxyRuntimeFixture.FakeSystemProxy!
  private var settingsStore: InMemorySettingsStore!
  private var probe: FakeOccupancyProbe!

  override func setUpWithError() throws {
    try super.setUpWithError()
    runtime = ProxyRuntimeFixture.makeTemporaryRuntime()
    catalogFileURL = runtime.directory.appendingPathComponent("catalog.json")
    activationFileURL = runtime.directory.appendingPathComponent("activation.json")
    credentials = InMemoryCredentialStore()
    agent = ProxyRuntimeFixture.FakeLaunchAgent()
    systemProxy = ProxyRuntimeFixture.FakeSystemProxy()
    settingsStore = InMemorySettingsStore()
    probe = FakeOccupancyProbe()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: runtime.directory)
    try super.tearDownWithError()
  }

  func testSaveCommitsThroughTheRuntimeController() async throws {
    let pair = makePair()

    pair.workflow.draft.timeoutSeconds = 120
    _ = await pair.workflow.save()

    XCTAssertEqual(settingsStore.saved?.timeoutSeconds, 120)
    XCTAssertEqual(pair.controller.settings.timeoutSeconds, 120)
    XCTAssertEqual(
      pair.workflow.draft, SettingsDraftAdapter.draft(from: pair.controller.settings),
      "提交后草稿回到已提交快照")
  }

  func testOccupiedPortMatchingTheRunningRuntimeDoesNotBlockSave() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11086])
    let pair = try await makeRunningPair()

    _ = await pair.workflow.reloadFromCommitted()
    await waitUntil(pair.workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertEqual(
      pair.workflow.portFieldState(for: .socks).occupancy, .occupied(occupier: "other-app"))
    XCTAssertTrue(
      pair.workflow.portFieldState(for: .socks).isRuntimePortException,
      "代理自身监听的端口不算冲突")
    XCTAssertFalse(pair.workflow.hasBlockingPortOccupancy)
    XCTAssertTrue(pair.workflow.canSave)

    pair.workflow.draft.timeoutSeconds = 120
    _ = await pair.workflow.save()
    XCTAssertEqual(settingsStore.saved?.timeoutSeconds, 120)
  }

  func testPACPortChangeRequiresConfirmationBeforeCommitting() async throws {
    let pair = makePair()

    pair.workflow.draft.pacPort = 13089
    _ = await pair.workflow.save()
    XCTAssertNotNil(pair.workflow.pendingConfirmation)
    XCTAssertNil(settingsStore.saved, "未确认失效提示不得提交")

    _ = await pair.workflow.confirmPACNotice()
    XCTAssertNil(pair.workflow.pendingConfirmation)
    XCTAssertEqual(pair.controller.settings.listen.pacPort, 13089)
  }

  func testCommitFailureSurfacesPresentedReasonAndKeepsCommittedValues() async throws {
    settingsStore.saveError = FakeSaveError.io
    let pair = makePair()

    pair.workflow.draft.timeoutSeconds = 120
    _ = await pair.workflow.save()

    XCTAssertEqual(pair.workflow.lastFailure, .unknown)
    XCTAssertEqual(pair.workflow.lastFailure?.presentableMessage, AppPresentation.unknownError)
    XCTAssertNil(settingsStore.saved)
    XCTAssertEqual(pair.controller.settings.timeoutSeconds, 60, "失败保留旧值")
    XCTAssertEqual(pair.workflow.draft.timeoutSeconds, 120, "草稿保留待修改值")
  }

  func testConfirmedResetRestoresFactorySnapshotThroughTheRuntimeController() async throws {
    let pair = makePair()
    var custom = pair.controller.settings
    custom.timeoutSeconds = 120
    _ = try await pair.controller.updateSettings(custom)
    XCTAssertEqual(pair.controller.settings.timeoutSeconds, 120)

    _ = await pair.workflow.reset()
    XCTAssertNotNil(pair.workflow.pendingConfirmation, "重置恒先经 seam 裁定的确认")
    _ = await pair.workflow.confirmReset()

    XCTAssertEqual(pair.workflow.draft, SettingsDraftAdapter.draft(from: ProxySettings()))
    XCTAssertNil(settingsStore.saved)
  }

  // MARK: - 夹具

  private func makePair() -> (controller: ProxyRuntimeController, workflow: SettingsWorkflow) {
    let catalogSnapshotReader = CatalogCommitCoordinator.bootstrap(
      fileStore: CatalogFileStore(fileURL: catalogFileURL)
    ).catalogSnapshotReader
    let controller = ProxyRuntimeController(
      catalogSnapshotReader: catalogSnapshotReader,
      activationFileStore: ActivationStateFileStore(fileURL: activationFileURL),
      runtimeFileStore: RuntimeFileStore(fileURL: runtime.contract),
      credentials: credentials,
      plugins: ActivationFixture.plugins,
      listenRestore: RestoredListenSettings(
        settings: ActivationFixture.listen, unreadableError: nil),
      settingsStore: settingsStore,
      agent: agent,
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      pacProbe: ProxyRuntimeFixture.FakePACProbe(),
      systemProxy: systemProxy,
      firewallExecutableURLs: [URL(fileURLWithPath: "/bundle/Helpers/sslocal")],
      firewallPollIntervalNanoseconds: 1_000_000,
      sendSignal: { _, _ in 0 })
    let workflow = SettingsWorkflow(committing: controller, occupancyProbe: probe)
    return (controller, workflow)
  }

  private func makeRunningPair() async throws -> (
    controller: ProxyRuntimeController, workflow: SettingsWorkflow
  ) {
    var catalog = ConfigurationCatalog()
    let server = try ActivationFixture.addPlainServer(
      "香港 01", in: &catalog, credentials: credentials)
    try CatalogFileStore(fileURL: catalogFileURL).save(CatalogDocument(catalog: catalog))
    let pair = makePair()
    try await pair.controller.activate(server)
    await pair.controller.setProxyEnabled(true)
    await waitUntil(pair.controller.state == .running)
    return pair
  }

  private enum FakeSaveError: Error, CustomStringConvertible {
    case io

    var description: String { "fake-io-error" }
  }

  final class InMemorySettingsStore: ProxySettingsStoring {
    var saved: ProxySettings?
    var saveError: Error?

    func load() throws -> ProxySettings {
      saved ?? ProxySettings()
    }

    func save(_ settings: ProxySettings) throws {
      if let saveError { throw saveError }
      saved = settings
    }

    func reset() throws {
      saved = nil
    }
  }
}
