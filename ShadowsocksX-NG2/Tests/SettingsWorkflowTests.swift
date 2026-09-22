import XCTest

@testable import ShadowsocksX_NG2

/// 设置工作流 module（Candidate 02）：保存门禁、占用反应、「当前运行端口」例外、
/// PAC 失效确认、建议端口与重置的编排路径不经 SwiftUI 即可全测（占用探测与
/// 运行时依赖全部注入替身）。
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

  func testEditingListenSettingsRefreshesOccupancyAndBlocksSave() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [12086])
    let pair = makePair()

    pair.workflow.draft.listen.socksPort = 12086
    await waitUntil(pair.workflow.occupancy[.socks] != nil)

    guard case .occupied = pair.workflow.occupancy[.socks] else {
      XCTFail("应呈现占用，实际 \(String(describing: pair.workflow.occupancy[.socks]))")
      return
    }
    XCTAssertFalse(pair.workflow.isCurrentRuntimePort(.socks))
    XCTAssertTrue(pair.workflow.hasOccupiedPort)
    XCTAssertFalse(pair.workflow.canSave)

    pair.workflow.save()
    await waitUntil(!pair.workflow.isSaving)
    XCTAssertNil(settingsStore.saved, "门禁未过不得提交")
  }

  func testOccupiedPortMatchingTheRunningRuntimeDoesNotBlockSave() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11086])
    let pair = try await makeRunningPair()

    pair.workflow.reloadFromCommitted()
    await waitUntil(pair.workflow.occupancy[.socks] != nil)

    guard case .occupied = pair.workflow.occupancy[.socks] else {
      XCTFail("替身应把运行端口报告为占用")
      return
    }
    XCTAssertTrue(pair.workflow.isCurrentRuntimePort(.socks), "代理自身监听的端口不算冲突")
    XCTAssertFalse(pair.workflow.hasOccupiedPort)
    XCTAssertTrue(pair.workflow.canSave)

    pair.workflow.draft.timeoutSeconds = 120
    pair.workflow.save()
    await waitUntil(settingsStore.saved != nil)
    XCTAssertEqual(settingsStore.saved?.timeoutSeconds, 120)
    XCTAssertEqual(pair.controller.settings.timeoutSeconds, 120)
    XCTAssertEqual(pair.workflow.draft, pair.controller.settings, "提交后草稿回到已提交快照")
  }

  func testPACPortChangeRequiresConfirmationBeforeCommitting() async throws {
    let pair = makePair()

    pair.workflow.draft.listen.pacPort = 13089
    await waitUntil(pair.workflow.occupancy[.pac] != nil)
    pair.workflow.save()

    XCTAssertNotNil(pair.workflow.pendingPACNotice)
    XCTAssertNil(settingsStore.saved, "未确认失效提示不得提交")

    pair.workflow.confirmPACNotice()
    await waitUntil(settingsStore.saved != nil)
    XCTAssertNil(pair.workflow.pendingPACNotice)
    XCTAssertEqual(pair.controller.settings.listen.pacPort, 13089)
  }

  func testCancelingPACNoticeDiscardsThePendingSave() async throws {
    let pair = makePair()

    pair.workflow.draft.listen.pacPort = 13089
    await waitUntil(pair.workflow.occupancy[.pac] != nil)
    pair.workflow.save()
    pair.workflow.cancelPACNotice()

    XCTAssertNil(pair.workflow.pendingPACNotice)
    XCTAssertNil(settingsStore.saved)
    XCTAssertEqual(pair.controller.settings.listen.pacPort, 11089, "取消后已提交值保持")
  }

  func testValidationErrorsBlockSave() async throws {
    let pair = makePair()

    pair.workflow.draft.timeoutSeconds = 0
    XCTAssertFalse(pair.workflow.validationErrors.isEmpty)
    XCTAssertFalse(pair.workflow.canSave)

    pair.workflow.save()
    await waitUntil(!pair.workflow.isSaving)
    XCTAssertNil(settingsStore.saved)
  }

  func testCommitFailureSurfacesPresentedReasonAndKeepsCommittedValues() async throws {
    settingsStore.saveError = FakeSaveError.io
    let pair = makePair()

    pair.workflow.draft.timeoutSeconds = 120
    pair.workflow.save()
    await waitUntil(pair.workflow.errorMessage != nil)

    XCTAssertTrue(pair.workflow.errorMessage?.contains("fake-io-error") == true)
    XCTAssertNil(settingsStore.saved)
    XCTAssertEqual(pair.controller.settings.timeoutSeconds, 60, "失败保留旧值")
    XCTAssertEqual(pair.workflow.draft.timeoutSeconds, 120, "草稿保留待修改值")
  }

  func testResetRestoresFactorySnapshotIntoTheDraft() async throws {
    let pair = makePair()
    var custom = pair.controller.settings
    custom.timeoutSeconds = 120
    try await pair.controller.updateSettings(custom)
    XCTAssertEqual(pair.controller.settings.timeoutSeconds, 120)

    pair.workflow.reset()
    await waitUntil(pair.controller.settings == ProxySettings())

    XCTAssertEqual(pair.workflow.draft, ProxySettings())
    XCTAssertNil(settingsStore.saved)
  }

  func testSuggestPortWritesCandidateIntoDraftOnly() async throws {
    let pair = makePair()

    pair.workflow.suggestPort(for: .socks)
    await waitUntil(pair.workflow.draft.listen.socksPort != 11086)

    XCTAssertEqual(pair.workflow.draft.listen.socksPort, 32768, "高位段首个空闲且避开其他端点")
    XCTAssertNil(settingsStore.saved, "建议只写草稿，必须经用户保存")
  }

  // MARK: - 夹具

  private func makePair() -> (controller: ProxyRuntimeController, workflow: SettingsWorkflow) {
    let controller = ProxyRuntimeController(
      catalogFileStore: CatalogFileStore(fileURL: catalogFileURL),
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
    let workflow = SettingsWorkflow(controller: controller, occupancyProbe: probe)
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

  private func waitUntil(
    _ condition: @autoclosure () -> Bool,
    timeout: TimeInterval = 2,
    file: StaticString = #filePath,
    line: UInt = #line
  ) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() && Date() < deadline {
      try? await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertTrue(condition(), file: file, line: line)
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

/// 占用探测替身：按端口预设占用/不可判定，记录全部探测请求。
final class FakeOccupancyProbe: PortOccupancyProbing, @unchecked Sendable {
  private let lock = NSLock()
  private let occupiedPorts: Set<Int>
  private var unknownPorts: Set<Int>
  private var requestedPorts: [Int] = []

  init(occupiedPorts: Set<Int> = [], unknownPorts: Set<Int> = []) {
    self.occupiedPorts = occupiedPorts
    self.unknownPorts = unknownPorts
  }

  var requested: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return requestedPorts
  }

  func occupancy(port: Int, bindAddress: String) -> PortOccupancy {
    lock.lock()
    defer { lock.unlock() }
    requestedPorts.append(port)
    if unknownPorts.contains(port) {
      return .unknown(detail: "无法判定")
    }
    return occupiedPorts.contains(port) ? .occupied(occupier: "other-app") : .free
  }
}
