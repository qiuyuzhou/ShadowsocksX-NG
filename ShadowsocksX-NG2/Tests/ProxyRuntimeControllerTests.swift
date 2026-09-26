import Combine
import XCTest

@testable import ShadowsocksX_NG2

/// 代理运行时控制器（issue #27/#60）：以替身注入 LaunchAgent 与端点探测，验证
/// agent 开关与系统代理开关的独立语义、目录重展开消费与 GUI 重同步重合（不
/// 触真实 SMAppService/launchd/SystemConfiguration）。
@MainActor
final class ProxyRuntimeControllerTests: XCTestCase {
  private var runtime: ProxyRuntimeFixture.TemporaryRuntime!
  private var catalogFileURL: URL!
  private var activationFileURL: URL!
  private var credentials: InMemoryCredentialStore!
  var agent: ProxyRuntimeFixture.FakeLaunchAgent!
  var systemProxy: ProxyRuntimeFixture.FakeSystemProxy!
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
  private func makeSeededCatalog() throws -> (catalog: ConfigurationCatalog, server: NodeID) {
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
    processIsAlive: @escaping @Sendable (Int32) -> Bool = { $0 == 42 }
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
          exceptions: ProxySettings().proxyExceptionList)
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

  func testLoopbackScopeNeverQueriesApplicationFirewallAndPublishesPACURL() async throws {
    let seeded = try makeSeededCatalog()
    let firewall = ProxyRuntimeFixture.FakeFirewallChecker(.blocked)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), firewallChecker: firewall)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    XCTAssertEqual(controller.state, .running)
    XCTAssertTrue(firewall.checkedURLs.isEmpty, "回环态与应用防火墙零交互")
    XCTAssertEqual(controller.pacURL?.absoluteString, "http://127.0.0.1:11089/v1/proxy.pac")
  }

  func testHostScopeBlockedByFirewallPresentsTargetedRepairAndKeepsPACURL() async throws {
    let seeded = try makeSeededCatalog()
    let firewall = ProxyRuntimeFixture.FakeFirewallChecker(.blocked)
    let listen = SslocalListenSettings(
      scope: .host(advertisedAddress: "192.168.2.89"),
      socksPort: 1086,
      httpPort: 1087,
      pacPort: 1089)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      listen: listen,
      firewallChecker: firewall)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    guard case .firewallBlocked(let facts) = controller.state else {
      XCTFail("主机态被拒应呈现防火墙状态，实际 \(controller.state)")
      return
    }
    XCTAssertEqual(facts.executableName, "sslocal")
    XCTAssertTrue(AppPresentation.message(for: controller.state).contains("允许传入连接"))
    XCTAssertEqual(firewall.checkedURLs.map(\.lastPathComponent), ["sslocal"])
    XCTAssertEqual(controller.pacURL?.absoluteString, "http://192.168.2.89:1089/v1/proxy.pac")
  }

  func testHostScopeDetectsFirewallRefusalAfterInitialHealthyPresentation() async throws {
    let seeded = try makeSeededCatalog()
    let firewall = ProxyRuntimeFixture.FakeFirewallChecker(outcomes: [.permitted, .blocked])
    let listen = SslocalListenSettings(scope: .host(advertisedAddress: "192.168.2.89"))
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      listen: listen,
      firewallChecker: firewall)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    let deadline = Date().addingTimeInterval(1)
    while controller.state == .running && Date() < deadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    guard case .firewallBlocked(let facts) = controller.state else {
      XCTFail("稍后发生的拒绝也必须被检测，实际 \(controller.state)")
      return
    }
    XCTAssertEqual(facts.executableName, "sslocal")
    XCTAssertTrue(AppPresentation.message(for: controller.state).contains("允许传入连接"))
    XCTAssertGreaterThanOrEqual(firewall.checkedURLs.count, 2)
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

  // MARK: GUI 重启重同步（D5）

  func testResyncWithRegisteredAgentAndMatchingContractSkipsRewrite() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), agentStatus: .notRegistered)
    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
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

  func testLegacyImportBoundaryStopsRuntimeWithoutRestoringSystemProxy() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    var importedSettings = ProxySettings()
    importedSettings.preferredMode = .global
    settingsStore.saved = importedSettings
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      systemProxy: systemProxy)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)
    XCTAssertEqual(controller.state, .running)

    await controller.legacyImportDidCommit()

    XCTAssertEqual(controller.state, .off)
    XCTAssertEqual(controller.settings, importedSettings)
    XCTAssertEqual(controller.activeTargetID, seeded.server)
    XCTAssertEqual(systemProxy.restoreCount, 0, "Legacy 导入不能写入或恢复系统代理")
    XCTAssertTrue(systemProxy.applied.isEmpty, "导入边界不应重新应用系统代理")
  }

  func testUpdatingSettingsPersistsAndReactivatesTheRuntimeContract() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true))

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    var next = controller.settings
    next.timeoutSeconds = 120
    next.verboseLogging = true
    next.proxyExceptions = "localhost, 127.0.0.1"
    try await controller.updateSettings(next)

    let document = try XCTUnwrap(RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertEqual(controller.settings, next)
    XCTAssertEqual(settingsStore.saved, next)
    XCTAssertEqual(document.timeout, 120)
    XCTAssertTrue(document.pac.verbose)
    XCTAssertEqual(
      systemProxy.applied.last?.exceptions,
      ["localhost", "127.0.0.1"], "系统代理意图开启时随设置更新重新应用")
  }

  private enum FakeSettingsSaveError: Error, CustomStringConvertible {
    case system

    var description: String { "fake-save-error" }
  }
}

extension ProxyRuntimeControllerTests {
  func testSetProxyModePersistsTheChoiceAndARestoreRestoresIt() async throws {
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)

    await controller.setProxyMode(.global)

    XCTAssertEqual(controller.proxyMode, .global)
    XCTAssertEqual(controller.settings.preferredMode, .global)
    XCTAssertEqual(settingsStore.saved?.preferredMode, .global, "模式选择随快照持久化")

    // GUI 重启路径：恢复出的控制器不注入显式模式，从持久快照读回。
    let restored = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsRestore: RestoredProxySettings(
        settings: try XCTUnwrap(settingsStore.load()), unreadableError: nil),
      proxyMode: nil)
    XCTAssertEqual(restored.proxyMode, .global)
  }

  func testSetProxyModePersistenceFailureKeepsPreviousModeAndNamesReason() async throws {
    let settingsStore = InMemoryProxySettingsStore()
    settingsStore.saveError = FakeSettingsSaveError.system
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)

    await controller.setProxyMode(.global)

    XCTAssertEqual(controller.proxyMode, .pac, "持久化失败保留旧模式")
    XCTAssertEqual(controller.settings.preferredMode, .pac)
    guard case .serviceFailed(.persistence) = controller.state else {
      XCTFail("应点名持久化失败，实际 \(controller.state)")
      return
    }
  }

  func testDirectModeDeploysACLWithoutServerAndProjectsSOCKSProxy() async throws {
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true))

    await controller.resyncOnLaunch()
    XCTAssertEqual(controller.state, .running)
    XCTAssertTrue(systemProxy.applied.isEmpty, "PAC 模式没有活动目标时不得接管")
    let unregisterCount = agent.unregisterCount

    await controller.setProxyMode(.direct)

    XCTAssertEqual(controller.proxyMode, .direct)
    XCTAssertEqual(controller.settings.preferredMode, .direct)
    XCTAssertEqual(settingsStore.saved?.preferredMode, .direct)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(agent.unregisterCount, unregisterCount + 1, "ACL 变化触发完整 agent 重启")
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let document = try XCTUnwrap(runtimeStore.loadDocument())
    XCTAssertTrue(document.servers.isEmpty, "直连模式允许空服务器列表")
    XCTAssertEqual(document.aclRuntime?.summary, "direct")
    XCTAssertEqual(
      try Data(contentsOf: runtimeStore.aclFileURL),
      Data(try XCTUnwrap(document.aclRuntime).content.utf8))
    XCTAssertEqual(
      systemProxy.applied.last?.target,
      .socks(host: "127.0.0.1", port: ActivationFixture.listen.socksPort))
    XCTAssertTrue(
      Set(FixedLocalProxyRanges.systemProxyExceptions).isSubset(
        of: Set(systemProxy.applied.last?.exceptions ?? [])))
    XCTAssertEqual(controller.systemProxyState, .applied)

    let registersBeforeDisable = agent.unregisterCount
    await controller.setSystemProxyEnabled(false)
    XCTAssertEqual(controller.state, .running, "关闭系统代理不停止本地入口")
    XCTAssertEqual(agent.unregisterCount, registersBeforeDisable)
    XCTAssertEqual(controller.systemProxyState, .idle)

    let restored = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsRestore: RestoredProxySettings(
        settings: try XCTUnwrap(settingsStore.load()), unreadableError: nil),
      proxyMode: nil)
    XCTAssertEqual(restored.proxyMode, .direct, "模式选择从持久快照恢复")
  }

  func testFailedDirectInstanceRestoresOldModeRuntimeAndSystemProxy() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true),
      launchHealthTimeoutSeconds: 0.05)
    try await controller.activate(seeded.server)
    XCTAssertEqual(controller.systemProxyState, .applied)
    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let previousDocument = try XCTUnwrap(runtimeStore.loadDocument())
    let previousApplicationCount = systemProxy.applied.count
    var observedStates: [ProxyRuntimeController.AgentRunState] = []
    let cancellable = controller.$state.sink { observedStates.append($0) }
    defer { cancellable.cancel() }

    agent.onRegister = { [runtimeStore, previousDocument] in
      guard let requested = runtimeStore.loadDocument() else { return }
      let accepted = requested.aclRuntime == nil ? requested : previousDocument
      try? runtimeStore.writeRuntimeReceipt(for: accepted, processID: 42)
    }

    await controller.setProxyMode(.direct)

    XCTAssertTrue(observedStates.contains(.starting), "重启期间呈现短暂不可用状态")
    XCTAssertEqual(controller.proxyMode, .pac, "新实例未验证时恢复旧模式")
    XCTAssertEqual(controller.settings.preferredMode, .pac)
    XCTAssertEqual(settingsStore.saved?.preferredMode, .pac)
    XCTAssertEqual(try runtimeStore.loadDocument(), previousDocument)
    XCTAssertNil(runtimeStore.loadDocument()?.aclRuntime)
    XCTAssertEqual(controller.state, .running, "旧运行时恢复后重新呈现健康")
    XCTAssertEqual(controller.systemProxyState, .applied)
    XCTAssertEqual(systemProxy.applied.count, previousApplicationCount)
    XCTAssertEqual(systemProxy.restoreCount, 0, "切换失败期间保持原系统代理应用")
  }

  /// Agent 开关持久化失败（issue #60）：保留现状并点名，不静默偏离持久化
  /// 事实（否则重启后意图被覆盖）。
  func testAgentTogglePersistenceFailureKeepsStateAndNamesReason() async throws {
    let settingsStore = InMemoryProxySettingsStore()
    settingsStore.saveError = FakeSettingsSaveError.system
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(listen: ActivationFixture.listen, agentEnabled: false))

    await controller.setAgentEnabled(true)

    XCTAssertEqual(controller.state, .serviceFailed(.persistence))
    XCTAssertFalse(controller.agentIntentEnabled, "持久化失败不改变内存意图")
    XCTAssertEqual(agent.registerCount, 0, "意图未落地前不收敛运行时")
  }
}

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
          target: .pac(URL(string: "http://127.0.0.1:11089/v1/proxy.pac")!),
          exceptions: ProxySettings().proxyExceptionList)
      ],
      "系统代理只在本地端点健康且存在可用出口后写入")
  }
  /// 端点不健康时系统代理意图保持待应用；条件恢复后随下次收敛自动应用，
  /// 无需重新开关系统代理（issue #60「条件恢复后自动收敛」）。
  func testSystemProxyIntentStaysPendingUntilEndpointsRecover() async throws {
    let seeded = try makeSeededCatalog()
    let probe = ProxyRuntimeFixture.FakeProbe.refusing()
    let controller = makeController(probe: probe)

    // 激活即按默认意图部署：端点持续不可达 → 启动失败（走满 15 秒健康窗）。
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

    // 激活即按默认意图部署：端点不可达 → 启动失败（走满 15 秒健康窗）。
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

private final class ProcessLivenessRecorder: @unchecked Sendable {
  private let lock = NSLock()
  private var candidateChecks = 0

  func isAlive(_ pid: Int32) -> Bool {
    if pid == 42 { return true }
    guard pid == 43 else { return false }
    lock.lock()
    defer { lock.unlock() }
    candidateChecks += 1
    return candidateChecks == 1
  }
}

extension ProxyRuntimeControllerTests {
  func testDirectReceiptIsRecheckedAfterReachableStaleListenerProbes() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let processLiveness = ProcessLivenessRecorder()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settings: ProxySettings(
        listen: ActivationFixture.listen, systemProxyEnabled: true),
      processIsAlive: { processLiveness.isAlive($0) })
    try await controller.activate(seeded.server)
    XCTAssertEqual(controller.systemProxyState, .applied)

    let runtimeStore = RuntimeFileStore(fileURL: runtime.contract)
    let previousDocument = try XCTUnwrap(runtimeStore.loadDocument())
    let appliedCount = systemProxy.applied.count
    agent.onRegister = { [runtimeStore] in
      guard let requested = runtimeStore.loadDocument() else { return }
      let processID: Int32 = requested.aclRuntime == nil ? 42 : 43
      try? runtimeStore.writeRuntimeReceipt(for: requested, processID: processID)
    }

    await controller.setProxyMode(.direct)

    XCTAssertEqual(controller.proxyMode, .pac, "探测期间新子进程退出时回滚旧模式")
    XCTAssertEqual(controller.state, .running, "旧实例应保持健康")
    XCTAssertEqual(runtimeStore.loadDocument(), previousDocument)
    XCTAssertEqual(controller.systemProxyState, .applied)
    XCTAssertEqual(systemProxy.applied.count, appliedCount, "旧系统代理保持应用")
    XCTAssertEqual(systemProxy.restoreCount, 0)
  }
}
