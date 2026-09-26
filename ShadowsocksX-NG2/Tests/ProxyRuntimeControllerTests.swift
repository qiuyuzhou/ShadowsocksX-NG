import Combine
import XCTest

@testable import ShadowsocksX_NG2

/// 代理运行时控制器（issue #27/#60）：以替身注入 LaunchAgent 与端点探测，验证
/// agent 开关与系统代理开关的独立语义、目录重展开消费与 GUI 重同步重合（不
/// 触真实 SMAppService/launchd/SystemConfiguration）。
@MainActor
final class ProxyRuntimeControllerTests: XCTestCase {
  var runtime: ProxyRuntimeFixture.TemporaryRuntime!
  var catalogFileURL: URL!
  var activationFileURL: URL!
  private var credentials: InMemoryCredentialStore!
  var agent: ProxyRuntimeFixture.FakeLaunchAgent!
  var systemProxy: ProxyRuntimeFixture.FakeSystemProxy!
  var signals: SignalRecorder!

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
    runtime = ProxyRuntimeFixture.makeTemporaryRuntime()
    catalogFileURL = runtime.directory.appendingPathComponent("catalog.json")
    activationFileURL = runtime.directory.appendingPathComponent("activation.json")
    credentials = InMemoryCredentialStore()
    agent = ProxyRuntimeFixture.FakeLaunchAgent()
    systemProxy = ProxyRuntimeFixture.FakeSystemProxy()
    signals = SignalRecorder()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: runtime.directory)
    try super.tearDownWithError()
  }

  /// 建一个含单台服务器的目录并落盘（服务器密码进内存凭据存储）。
  func makeSeededCatalog() throws -> (catalog: ConfigurationCatalog, server: NodeID) {
    var catalog = ConfigurationCatalog()
    let server = try ActivationFixture.addPlainServer(
      "香港 01", in: &catalog, credentials: credentials)
    try CatalogFileStore(fileURL: catalogFileURL).save(CatalogDocument(catalog: catalog))
    return (catalog, server)
  }

  func makeController(
    probe: EndpointProbing,
    agentStatus: LaunchAgentStatus = .notRegistered,
    listen: SslocalListenSettings = ActivationFixture.listen,
    settingsStore: ProxySettingsStoring? = nil,
    settings: ProxySettings? = nil,
    settingsRestore: RestoredProxySettings? = nil,
    pacProbe: PACHealthProbing = ProxyRuntimeFixture.FakePACProbe(),
    proxyMode: ProxyMode? = .pac,
    systemProxy: SystemProxyControlling? = nil,
    firewallChecker: FirewallStatusChecking = ProxyRuntimeFixture.FakeFirewallChecker(),
    firewallExecutableURLs: [URL] = [URL(fileURLWithPath: "/bundle/Helpers/sslocal")],
    firewallPollIntervalNanoseconds: UInt64 = 1_000_000,
    launchHealthTimeoutSeconds: TimeInterval = 15,
    processIsAlive: @escaping @Sendable (Int32) -> Bool = { $0 == 42 },
    customRuleStore: CustomRuleStore? = nil
  ) -> ProxyRuntimeController {
    agent.setStatus(agentStatus)
    let runtimeFileStore = RuntimeFileStore(fileURL: runtime.contract)
    agent.onRegister = { [runtimeFileStore] in
      guard let document = runtimeFileStore.loadDocument() else { return }
      try? runtimeFileStore.writeRuntimeReceipt(for: document, processID: 42)
    }
    let restored =
      settingsRestore
      ?? RestoredProxySettings(
        settings: settings ?? ProxySettings(listen: listen), unreadableError: nil)
    return ProxyRuntimeController(
      catalogSnapshotReader: ProxyRuntimeFixture.catalogSnapshotReader(at: catalogFileURL),
      activationFileStore: ActivationStateFileStore(fileURL: activationFileURL),
      runtimeFileStore: runtimeFileStore,
      credentials: credentials,
      plugins: ActivationFixture.plugins,
      listenRestore: RestoredListenSettings(settings: listen, unreadableError: nil),
      settingsStore: settingsStore ?? InMemoryProxySettingsStore(),
      customRuleStore: customRuleStore
        ?? CustomRuleStore(fileURL: runtime.directory.appendingPathComponent("custom-rules.json")),
      settingsRestore: restored,
      agent: agent,
      probe: probe,
      pacProbe: pacProbe,
      systemProxy: systemProxy ?? self.systemProxy,
      proxyMode: proxyMode,
      firewallChecker: firewallChecker,
      firewallExecutableURLs: firewallExecutableURLs,
      firewallPollIntervalNanoseconds: firewallPollIntervalNanoseconds,
      launchHealthTimeoutSeconds: launchHealthTimeoutSeconds,
      sendSignal: { [signals] pid, number in signals!.send(pid, number) },
      processIsAlive: processIsAlive)
  }

  // MARK: Agent 开关与首次默认

  func testActivateWhileAgentOffPublishesActiveTargetIDWithoutDeploying() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))
    var observed: NodeID?
    let cancellable = controller.$activeTargetID.dropFirst().sink { observed = $0 }
    defer { cancellable.cancel() }

    try await controller.activate(seeded.server)

    XCTAssertEqual(controller.activeTargetID, seeded.server)
    XCTAssertEqual(observed, seeded.server, "agent 关闭路径的激活也要发布目标变更")
    XCTAssertEqual(controller.state, .off, "agent 意图关闭时仅选择目标，不部署")
    XCTAssertEqual(agent.registerCount, 0)
  }

  func testActivateThenEnableWritesContractRegistersAndReachesRunning() async throws {
    let seeded = try makeSeededCatalog()
    let probe = ProxyRuntimeFixture.FakeProbe.reachable()
    let controller = makeController(probe: probe)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(agent.registerCount, 1)
    let persisted = try ActivationStateFileStore(fileURL: activationFileURL).loadActiveTargetID()
    XCTAssertEqual(persisted, seeded.server, "活动目标已持久化")
    let onDisk = try XCTUnwrap(
      RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertEqual(onDisk.servers.count, 1)
    XCTAssertEqual(onDisk.socksPort, ActivationFixture.listen.socksPort)
    XCTAssertEqual(onDisk.servers.first?.password, "pw-香港 01", "凭据已解析进文档")
    XCTAssertTrue(
      systemProxy.applied.isEmpty, "系统代理意图默认关闭：agent 运行也不写系统设置")
    XCTAssertEqual(probe.ports, [11086, 11087], "健康门先探测 SOCKS 和 HTTP 入站")
  }

  func testSwitchingGlobalAndPACModesIsImmediateAndRestoresOnAgentOff() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settings: ProxySettings(
        listen: ActivationFixture.listen,
        preferredMode: .global,
        systemProxyEnabled: true),
      proxyMode: .global)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    XCTAssertEqual(
      systemProxy.applied,
      [
        SystemProxyConfiguration(
          target: .socks(host: "127.0.0.1", port: 11086),
          exceptions: FixedLocalProxyRanges.systemProxyExceptions(
            including: ProxySettings().proxyExceptionList))
      ])

    await controller.setProxyMode(.pac)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(systemProxy.applied.count, 2)
    XCTAssertEqual(
      systemProxy.applied.last,
      SystemProxyConfiguration(
        target: .pac(URL(string: "http://127.0.0.1:11089/v1/proxy.pac")!),
        exceptions: ProxySettings().proxyExceptionList))

    await controller.setAgentEnabled(false)
    XCTAssertEqual(controller.state, .off)
    XCTAssertEqual(systemProxy.restoreCount, 1, "关闭 agent 撤除 2.0 写入的系统代理")
  }

  func testEnableWhenProbeNeverSucceedsPresentsFailureNamingEndpointAndPort() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.refusing(), agentStatus: .notRegistered)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    guard case .launchFailed(.localEndpoint(_, _, let port, let cause)) = controller.state else {
      XCTFail("应呈现启动失败，实际 \(controller.state)")
      return
    }
    XCTAssertEqual(port, 11086)
    XCTAssertEqual(cause, .refused)
    XCTAssertTrue(systemProxy.applied.isEmpty, "端点不健康时不得写系统代理")
    XCTAssertEqual(controller.systemProxyState, .idle, "系统代理意图默认关闭")
  }

  func testDisableAgentUnregistersAndCleansRuntimeFiles() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    await controller.setAgentEnabled(false)

    XCTAssertEqual(controller.state, .off)
    XCTAssertEqual(agent.unregisterCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.contract.path), "显式停止后清理契约")
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.pidFile.path))
  }

  // MARK: 目录重展开消费（D3/D5）

  func testCatalogEditOfActiveTargetRewritesAndSignalsRunningWrapper() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    // 模拟 wrapper 在跑：pid 指向本测试进程（kill(pid, 0) 判活通过）。
    try Data("\(ProcessInfo.processInfo.processIdentifier)".utf8).write(to: runtime.pidFile)

    // 修改服务器备注（文档内容随之变化），提交目录变更。
    var catalog = try CatalogFileStore(fileURL: catalogFileURL).load().catalog
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
    try CatalogFileStore(fileURL: catalogFileURL).save(CatalogDocument(catalog: catalog))

    // 协调器生产适配入口（issue #40）：以刚提交的内存快照重展开。
    let committed = try CatalogFileStore(fileURL: catalogFileURL).load().catalog
    await controller.catalogDidCommit(snapshot: committed)

    XCTAssertEqual(controller.state, .running)
    let expectedRemark = "新加坡 01"
    let onDisk = try XCTUnwrap(RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertEqual(onDisk.servers.first?.remarks, expectedRemark, "运行时文档已原子更新")
    let signalsSent = signals.signalsSent.filter { $0.signal != 0 }
    XCTAssertEqual(signalsSent.count, 1, "代理运行中：重写后应发一次 SIGUSR1")
    XCTAssertEqual(signalsSent.first?.signal, SIGUSR1)
  }
}
