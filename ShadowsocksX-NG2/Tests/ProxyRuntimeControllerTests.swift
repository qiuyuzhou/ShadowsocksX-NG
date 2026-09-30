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
  var credentials: InMemoryCredentialStore!
  var agent: ProxyRuntimeFixture.FakeLaunchAgent!
  var systemProxy: ProxyRuntimeFixture.FakeSystemProxy!
  var systemProxyHelper: ProxyRuntimeFixture.FakeSystemProxyHelperService!
  var systemProxyNetworkChangeMonitor: ProxyRuntimeFixture.FakeSystemProxyNetworkChangeMonitor!
  var signals: SignalRecorder!

  /// SIGUSR1 投递记录缝。
  final class SignalRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [(pid: Int32, signal: Int32)] = []
    /// SIGUSR1 送达后模拟 wrapper 热重载刷新回执。
    var reloadReceipt: (() -> Void)?

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
      if signal == SIGUSR1 {
        reloadReceipt?()
      }
      // kill(_, 0) 判活语义：只对夹具约定的存活 pid（42 与本测试进程）报告
      // 在跑；陈旧残留 pid 返回 ESRCH，停止协议才不必空等退出超时上限。
      if signal == 0 {
        return pid == 42 || pid == ProcessInfo.processInfo.processIdentifier
          ? 0 : Int32(ESRCH)
      }
      return 0
    }
  }

  override func setUp() async throws {
    try await super.setUp()
    runtime = ProxyRuntimeFixture.makeTemporaryRuntime()
    catalogFileURL = runtime.directory.appendingPathComponent("catalog.json")
    activationFileURL = runtime.directory.appendingPathComponent("activation.json")
    credentials = InMemoryCredentialStore()
    agent = ProxyRuntimeFixture.FakeLaunchAgent()
    systemProxy = ProxyRuntimeFixture.FakeSystemProxy()
    systemProxyHelper = ProxyRuntimeFixture.FakeSystemProxyHelperService()
    systemProxyNetworkChangeMonitor = ProxyRuntimeFixture.FakeSystemProxyNetworkChangeMonitor()
    signals = SignalRecorder()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: runtime.directory)
    try await super.tearDown()
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
    proxyMode: ProxyMode? = .rule,
    systemProxy: SystemProxyControlling? = nil,
    networkChangeMonitor: SystemProxyNetworkChangeMonitoring? = nil,
    firewallChecker: FirewallStatusChecking = ProxyRuntimeFixture.FakeFirewallChecker(),
    firewallExecutableURLs: [URL] = [URL(fileURLWithPath: "/bundle/Helpers/sslocal")],
    firewallPollIntervalNanoseconds: UInt64 = 1_000_000,
    // 生产默认 15 秒健康窗；FakeProbe 结果确定，短窗口走同一超时呈现路径。
    launchHealthTimeoutSeconds: TimeInterval = 0.05,
    // 漂移重注的注销-重注间隔与用例无关，缩短保持套件快速。
    helperRefreshDelayNanoseconds: UInt64 = 10_000_000,
    processIsAlive: @escaping @Sendable (Int32) -> Bool = { $0 == 42 },
    customRuleStore: CustomRuleStore? = nil
  ) -> ProxyRuntimeController {
    agent.setStatus(agentStatus)
    let runtimeFileStore = RuntimeFileStore(fileURL: runtime.contract)
    agent.onRegister = { [runtimeFileStore] in
      guard let document = runtimeFileStore.loadDocument() else { return }
      try? runtimeFileStore.writeRuntimeReceipt(for: document, processID: 42)
    }
    // SIGUSR1 模拟 wrapper 热重载后刷新回执（真实 wrapper 会如此）。
    signals.reloadReceipt = { [runtimeFileStore] in
      guard let document = runtimeFileStore.loadDocument() else { return }
      try? runtimeFileStore.writeRuntimeReceipt(for: document, processID: 42)
    }
    let restored =
      settingsRestore
      ?? RestoredProxySettings(
        // 控制器行为用例默认「用户已打开 Agent」；出厂默认 off 由 ProxySettingsTests 锁定。
        settings: settings ?? ProxySettings(listen: listen, agentEnabled: true),
        unreadableError: nil)
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
      appBundle: AppArtifact.bundle,
      settingsRestore: restored,
      agent: agent,
      probe: probe,
      systemProxy: systemProxy ?? self.systemProxy,
      systemProxyHelper: systemProxyHelper ?? self.systemProxyHelper,
      systemProxyNetworkChangeMonitor: networkChangeMonitor ?? systemProxyNetworkChangeMonitor,
      proxyMode: proxyMode,
      firewallChecker: firewallChecker,
      firewallExecutableURLs: firewallExecutableURLs,
      firewallPollIntervalNanoseconds: firewallPollIntervalNanoseconds,
      launchHealthTimeoutSeconds: launchHealthTimeoutSeconds,
      helperRefreshDelayNanoseconds: helperRefreshDelayNanoseconds,
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

  func testEffectiveRuntimeListenerProcessIDRequiresCurrentLiveReceipt() throws {
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), processIsAlive: { $0 == 42 })
    let document = SslocalRuntimeDocument(servers: [], listen: ActivationFixture.listen)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    try runtimeStore.write(document)
    try runtimeStore.writeRuntimeReceipt(for: document, processID: 42)
    controller.lastDocument = document
    controller.state = .running

    XCTAssertEqual(controller.effectiveRuntimeListenerProcessID, 42)

    let staleDocument = SslocalRuntimeDocument(
      servers: [],
      listen: SslocalListenSettings(socksPort: 11088, httpPort: 11089))
    try runtimeStore.writeRuntimeReceipt(for: staleDocument, processID: 42)
    XCTAssertNil(controller.effectiveRuntimeListenerProcessID, "回执必须匹配当前运行契约")

    try runtimeStore.writeRuntimeReceipt(for: document, processID: 42)
    controller.state = .off
    XCTAssertNil(controller.effectiveRuntimeListenerProcessID, "已停止 runtime 不得拥有监听器")
  }

  func testSwitchingGlobalAndRuleModesIsImmediateAndRestoresOnAgentOff() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settings: ProxySettings(
        listen: ActivationFixture.listen,
        preferredMode: .global,
        agentEnabled: true,
        systemProxyEnabled: true),
      proxyMode: .global)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    XCTAssertEqual(
      systemProxy.applied,
      [
        SystemProxyConfiguration(
          socks: .init(host: "127.0.0.1", port: 11086),
          http: .init(host: "127.0.0.1", port: 11087),
          https: .init(host: "127.0.0.1", port: 11087),
          exceptions: FixedLocalProxyRanges.systemProxyExceptions(
            including: ProxySettings().proxyExceptionList))
      ])

    await controller.setProxyMode(.rule)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(systemProxy.applied.count, 2)
    XCTAssertEqual(
      systemProxy.applied.last,
      SystemProxyConfiguration(
        socks: .init(host: "127.0.0.1", port: 11086),
        http: .init(host: "127.0.0.1", port: 11087),
        https: .init(host: "127.0.0.1", port: 11087),
        exceptions: FixedLocalProxyRanges.systemProxyExceptions(
          including: ProxySettings().proxyExceptionList)))

    await controller.setAgentEnabled(false)
    XCTAssertEqual(controller.state, .off)
    XCTAssertEqual(systemProxy.clearCount, 1, "关闭 agent 清除已应用的系统代理")
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

}
