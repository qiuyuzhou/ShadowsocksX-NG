import XCTest

@testable import ShadowsocksX_NG2

/// 代理运行时控制器（issue #27）：以替身注入 LaunchAgent 与端点探测，验证
/// 代理开关、目录重展开消费与 GUI 重同步重合（不触真实 SMAppService/launchd）。
@MainActor
final class ProxyRuntimeControllerTests: XCTestCase {
  private var runtime: ProxyRuntimeFixture.TemporaryV2!
  private var catalogFileURL: URL!
  private var activationFileURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var agent: ProxyRuntimeFixture.FakeLaunchAgent!
  private var signals: SignalRecorder!

  /// SIGUSR1 投递记录缝。
  final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [(pid: Int32, signal: Int32)] = []

    var signalsSent: [(pid: Int32, signal: Int32)] {
      lock.lock()
      defer { lock.unlock() }
      return records
    }

    func record(_ pid: Int32, _ signal: Int32) {
      lock.lock()
      records.append((pid, signal))
      lock.unlock()
    }

    func send(_ pid: Int32, _ signal: Int32) -> Int32 {
      record(pid, signal)
      return 0
    }
  }

  override func setUpWithError() throws {
    try super.setUpWithError()
    runtime = ProxyRuntimeFixture.makeTemporaryV2()
    catalogFileURL = runtime.directory.appendingPathComponent("catalog.json")
    activationFileURL = runtime.directory.appendingPathComponent("activation.json")
    credentials = InMemoryCredentialStore()
    agent = ProxyRuntimeFixture.FakeLaunchAgent()
    signals = SignalRecorder()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: runtime.directory)
    try super.tearDownWithError()
  }

  /// 建一个含单台服务器的目录并落盘（服务器密码进内存凭据存储）。
  private func makeSeededCatalog() throws -> (catalog: ConfigurationCatalog, server: NodeID) {
    var catalog = ConfigurationCatalog()
    let server = try ActivationFixture.addPlainServer(
      "香港 01", in: &catalog, credentials: credentials)
    try CatalogFileStore(fileURL: catalogFileURL).save(catalog)
    return (catalog, server)
  }

  private func makeController(
    probe: EndpointProbing,
    agentStatus: LaunchAgentStatus = .notRegistered
  ) -> ProxyRuntimeController {
    agent.setStatus(agentStatus)
    return ProxyRuntimeController(
      catalogFileStore: CatalogFileStore(fileURL: catalogFileURL),
      activationFileStore: ActivationStateFileStore(fileURL: activationFileURL),
      runtimeFileStore: RuntimeFileStore(fileURL: runtime.contract),
      credentials: credentials,
      plugins: ActivationFixture.plugins,
      listen: ActivationFixture.listen,
      agent: agent,
      probe: probe,
      sendSignal: { [signals] pid, number in signals!.send(pid, number) })
  }

  // MARK: 代理开关

  func testEnableWithoutActiveTargetPresentsNamedFailureAndStartsNothing() async throws {
    _ = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    await controller.setProxyEnabled(true)

    XCTAssertEqual(
      controller.state,
      .activationFailed(reason: "尚未激活任何服务器或分组，请先在主窗口激活后再启动代理"))
    XCTAssertEqual(agent.registerCount, 0, "无目标不触碰 launchd（无静默回退）")
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.contract.path))
  }

  func testActivateThenEnableWritesContractRegistersAndReachesRunning() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(agent.registerCount, 1)
    let persisted = try ActivationStateFileStore(fileURL: activationFileURL).loadActiveTargetID()
    XCTAssertEqual(persisted, seeded.server, "活动目标已持久化")
    let onDisk = try XCTUnwrap(
      RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertEqual(onDisk.servers.count, 1)
    XCTAssertEqual(onDisk.localPort, ActivationFixture.listen.localPort)
    XCTAssertEqual(onDisk.servers.first?.password, "pw-香港 01", "凭据已解析进文档")
  }

  func testEnableWhenProbeNeverSucceedsPresentsFailureNamingEndpointAndPort() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.refusing(), agentStatus: .notRegistered)

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

    guard case .launchFailed(let detail) = controller.state else {
      XCTFail("应呈现启动失败，实际 \(controller.state)")
      return
    }
    XCTAssertTrue(
      detail.contains("127.0.0.1") && detail.contains("1086"),
      "启动失败必须点名端点与端口（D8）：\(detail)")
  }

  func testDisableUnregistersAndCleansRuntimeFiles() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

    await controller.setProxyEnabled(false)

    XCTAssertEqual(controller.state, .off)
    XCTAssertEqual(agent.unregisterCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.contract.path), "显式停止后清理契约")
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.pidFile.path))
  }

  // MARK: 目录重展开消费（D3/D5）

  func testCatalogEditOfActiveTargetRewritesAndSignalsRunningWrapper() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)
    // 模拟 wrapper 在跑：pid 指向本测试进程（kill(pid, 0) 判活通过）。
    try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: runtime.pidFile)

    // 修改服务器备注（文档内容随之变化），提交目录变更。
    var catalog = try CatalogFileStore(fileURL: catalogFileURL).load()
    var fields = try ActivationFixture.serverFields(of: seeded.server, in: catalog)
    fields = ServerFields(
      address: fields.address,
      port: fields.port,
      encryptionMethod: fields.encryptionMethod,
      passwordRef: fields.passwordRef,
      remark: "新加坡 01",
      pluginProgram: fields.pluginProgram,
      pluginOptionsRef: fields.pluginOptionsRef)
    try catalog.updateServer(seeded.server, with: fields)
    try CatalogFileStore(fileURL: catalogFileURL).save(catalog)

    await controller.catalogDidCommit()

    XCTAssertEqual(controller.state, .running)
    let expectedRemark = "新加坡 01"
    let onDisk = try XCTUnwrap(RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertEqual(onDisk.servers.first?.remarks, expectedRemark, "运行时文档已原子更新")
    let signalsSent = signals.signalsSent.filter { $0.signal != 0 }
    XCTAssertEqual(signalsSent.count, 1, "代理运行中：重写后应发一次 SIGUSR1")
    XCTAssertEqual(signalsSent.first?.signal, SIGUSR1)
  }

  func testInvalidTargetOnCommitClearsPersistsNilAndStops() async throws {
    let seeded = try makeSeededCatalog()
    try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: runtime.pidFile)
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

    // 删除活动目标 → 重展开失败 → 清除并停止。
    var catalog = try CatalogFileStore(fileURL: catalogFileURL).load()
    try catalog.remove(seeded.server)
    try CatalogFileStore(fileURL: catalogFileURL).save(catalog)

    await controller.catalogDidCommit()

    guard case .activationFailed = controller.state else {
      XCTFail("应呈现点名原因，实际 \(controller.state)")
      return
    }
    let persisted = try ActivationStateFileStore(fileURL: activationFileURL).loadActiveTargetID()
    XCTAssertNil(persisted, "活动目标已清除")
    XCTAssertEqual(agent.unregisterCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.contract.path))
  }

  // MARK: GUI 重启重同步（D5）

  func testResyncWithRegisteredAgentAndMatchingContractSkipsRewrite() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), agentStatus: .notRegistered)
    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)
    XCTAssertTrue(agent.registerCount >= 1)
    let contractMtime =
      try FileManager.default.attributesOfItem(
        atPath: runtime.contract.path
      )[.modificationDate] as? Date

    // 模拟 GUI 重启：全新控制器，agent 已注册、wrapper pid 存活（本测试进程）。
    try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: runtime.pidFile)
    let restarted = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), agentStatus: .registered)

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

  func testResyncWithUnregisteredAgentCleansResidueAndStaysOff() async throws {
    let seeded = try makeSeededCatalog()
    try Data("stale contract".utf8).write(to: runtime.contract)
    try Data("99999".utf8).write(to: runtime.pidFile)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), agentStatus: .notRegistered)
    await controller.activate(seeded.server)
    try ActivationStateFileStore(fileURL: activationFileURL).save(activeTargetID: seeded.server)

    await controller.resyncOnLaunch()

    XCTAssertEqual(controller.state, .off, "未注册 = 代理意图关闭")
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.contract.path), "残留契约被清理")
    XCTAssertEqual(agent.registerCount, 0)
  }

  func testResyncWithInvalidActiveTargetClearsAndCleans() async throws {
    _ = try makeSeededCatalog()
    try Data("garbage".utf8).write(to: runtime.contract)
    let missingTarget = NodeID(rawValue: "removed-target")
    try ActivationStateFileStore(fileURL: activationFileURL).save(activeTargetID: missingTarget)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), agentStatus: .registered)

    await controller.resyncOnLaunch()

    guard case .activationFailed = controller.state else {
      XCTFail("应呈现点名原因，实际 \(controller.state)")
      return
    }
    let persisted = try ActivationStateFileStore(fileURL: activationFileURL).loadActiveTargetID()
    XCTAssertNil(persisted)
    XCTAssertEqual(agent.unregisterCount, 1, "注册过即按停止协议注销")
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.contract.path))
  }
}
