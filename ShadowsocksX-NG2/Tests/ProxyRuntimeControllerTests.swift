import Combine
import XCTest

@testable import ShadowsocksX_NG2

/// 代理运行时控制器（issue #27）：以替身注入 LaunchAgent 与端点探测，验证
/// 代理开关、目录重展开消费与 GUI 重同步重合（不触真实 SMAppService/launchd）。
@MainActor
final class ProxyRuntimeControllerTests: XCTestCase {
  private var runtime: ProxyRuntimeFixture.TemporaryRuntime!
  private var catalogFileURL: URL!
  private var activationFileURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var agent: ProxyRuntimeFixture.FakeLaunchAgent!
  private var systemProxy: ProxyRuntimeFixture.FakeSystemProxy!
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

  private func makeController(
    probe: EndpointProbing,
    agentStatus: LaunchAgentStatus = .notRegistered,
    listen: SslocalListenSettings = ActivationFixture.listen,
    settingsStore: ProxySettingsStoring? = nil,
    settingsRestore: RestoredProxySettings? = nil,
    pacProbe: PACHealthProbing = ProxyRuntimeFixture.FakePACProbe(),
    proxyMode: ProxyMode = .pac,
    systemProxy: SystemProxyControlling? = nil,
    firewallChecker: FirewallStatusChecking = ProxyRuntimeFixture.FakeFirewallChecker(),
    firewallExecutableURLs: [URL] = [URL(fileURLWithPath: "/bundle/Helpers/sslocal")],
    firewallPollIntervalNanoseconds: UInt64 = 1_000_000
  ) -> ProxyRuntimeController {
    agent.setStatus(agentStatus)
    return ProxyRuntimeController(
      catalogFileStore: CatalogFileStore(fileURL: catalogFileURL),
      activationFileStore: ActivationStateFileStore(fileURL: activationFileURL),
      runtimeFileStore: RuntimeFileStore(fileURL: runtime.contract),
      credentials: credentials,
      plugins: ActivationFixture.plugins,
      listenRestore: RestoredListenSettings(settings: listen, unreadableError: nil),
      settingsStore: settingsStore ?? InMemoryProxySettingsStore(),
      settingsRestore: settingsRestore,
      agent: agent,
      probe: probe,
      pacProbe: pacProbe,
      systemProxy: systemProxy ?? self.systemProxy,
      proxyMode: proxyMode,
      firewallChecker: firewallChecker,
      firewallExecutableURLs: firewallExecutableURLs,
      firewallPollIntervalNanoseconds: firewallPollIntervalNanoseconds,
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

  /// 菜单栏「目标」行的实时性（issue #31）：代理关闭时激活只改活动目标、
  /// 不触碰 state，目标变更必须仍经 @Published 发布到菜单。
  func testActivateWhileProxyOffPublishesActiveTargetID() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())
    var observed: NodeID?
    let cancellable = controller.$activeTargetID.dropFirst().sink { observed = $0 }
    defer { cancellable.cancel() }

    await controller.activate(seeded.server)

    XCTAssertEqual(controller.activeTargetID, seeded.server)
    XCTAssertEqual(observed, seeded.server, "代理关闭路径的激活也要发布目标变更")
    XCTAssertEqual(controller.state, .off, "仅激活不启动代理")
  }

  func testActivateThenEnableWritesContractRegistersAndReachesRunning() async throws {
    let seeded = try makeSeededCatalog()
    let probe = ProxyRuntimeFixture.FakeProbe.reachable()
    let controller = makeController(probe: probe)

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(agent.registerCount, 1)
    let persisted = try ActivationStateFileStore(fileURL: activationFileURL).loadActiveTargetID()
    XCTAssertEqual(persisted, seeded.server, "活动目标已持久化")
    let onDisk = try XCTUnwrap(
      RuntimeFileStore(fileURL: runtime.contract).loadDocument())
    XCTAssertEqual(onDisk.servers.count, 1)
    XCTAssertEqual(onDisk.socksPort, ActivationFixture.listen.socksPort)
    XCTAssertEqual(onDisk.servers.first?.password, "pw-香港 01", "凭据已解析进文档")
    XCTAssertEqual(
      systemProxy.applied,
      [
        SystemProxyConfiguration(
          target: .pac(URL(string: "http://127.0.0.1:1089/v1/proxy.pac")!),
          exceptions: ProxySettings().proxyExceptionList)
      ],
      "PAC 只有在本地 SOCKS 与 PAC 健康后才写入系统代理")
    XCTAssertEqual(probe.ports, [1086, 1087], "系统代理写入前必须探测 SOCKS 和 HTTP 入站")
  }

  func testExternalPACHealthFailureDoesNotWriteSystemProxy() async throws {
    let seeded = try makeSeededCatalog()
    let externalURL = URL(string: "https://pac.example.test/proxy.pac")!
    let pacProbe = ProxyRuntimeFixture.FakePACProbe(
      outcomes: [.reachable, .failed(detail: "HTTP 状态异常")])
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      pacProbe: pacProbe,
      proxyMode: .externalPAC(externalURL))

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

    guard case .systemProxyFailed(let detail) = controller.state else {
      XCTFail("外部 PAC 不健康时应阻止系统代理写入，实际 \(controller.state)")
      return
    }
    XCTAssertTrue(detail.contains("外部 PAC") && detail.contains("HTTP 状态异常"))
    XCTAssertTrue(systemProxy.applied.isEmpty)
    XCTAssertEqual(
      pacProbe.urls,
      [
        URL(string: "http://127.0.0.1:1089/v1/proxy.pac")!, externalURL,
      ])
  }

  func testSwitchingGlobalAndManualModesIsImmediateAndRestoresOnStop() async throws {
    let seeded = try makeSeededCatalog()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), proxyMode: .global)

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)
    XCTAssertEqual(
      systemProxy.applied,
      [
        SystemProxyConfiguration(
          target: .socks(host: "127.0.0.1", port: 1086),
          exceptions: ProxySettings().proxyExceptionList)
      ])

    await controller.setProxyMode(.manual)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(systemProxy.restoreCount, 1, "手动模式立即恢复原系统代理设置")

    await controller.setProxyMode(.pac)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(systemProxy.applied.count, 2)
    XCTAssertEqual(
      systemProxy.applied.last,
      SystemProxyConfiguration(
        target: .pac(URL(string: "http://127.0.0.1:1089/v1/proxy.pac")!),
        exceptions: ProxySettings().proxyExceptionList))

    await controller.setProxyEnabled(false)
    XCTAssertEqual(controller.state, .off)
    XCTAssertEqual(systemProxy.restoreCount, 2, "停止代理撤除 2.0 写入的系统代理")
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
    XCTAssertTrue(systemProxy.applied.isEmpty, "端点不健康时不得写系统代理")
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

  func testLoopbackScopeNeverQueriesApplicationFirewallAndPublishesPACURL() async throws {
    let seeded = try makeSeededCatalog()
    let firewall = ProxyRuntimeFixture.FakeFirewallChecker(.blocked)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), firewallChecker: firewall)

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

    XCTAssertEqual(controller.state, .running)
    XCTAssertTrue(firewall.checkedURLs.isEmpty, "回环态与应用防火墙零交互")
    XCTAssertEqual(controller.pacURL?.absoluteString, "http://127.0.0.1:1089/v1/proxy.pac")
  }

  func testHostScopeBlockedByFirewallPresentsTargetedRepairAndKeepsPACURL() async throws {
    let seeded = try makeSeededCatalog()
    let firewall = ProxyRuntimeFixture.FakeFirewallChecker(.blocked)
    let listen = SslocalListenSettings(
      scope: .host(advertisedAddress: "192.168.2.89"),
      socksPort: 1086,
      httpProxyEnabled: true,
      httpPort: 1087,
      pacPort: 1089)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      listen: listen,
      firewallChecker: firewall)

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

    guard case .firewallBlocked(let detail) = controller.state else {
      XCTFail("主机态被拒应呈现防火墙状态，实际 \(controller.state)")
      return
    }
    XCTAssertTrue(detail.contains("sslocal"))
    XCTAssertTrue(detail.contains("系统设置") && detail.contains("防火墙") && detail.contains("允许传入连接"))
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

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

    let deadline = Date().addingTimeInterval(1)
    while controller.state == .running && Date() < deadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    guard case .firewallBlocked(let detail) = controller.state else {
      XCTFail("稍后发生的拒绝也必须被检测，实际 \(controller.state)")
      return
    }
    XCTAssertTrue(detail.contains("sslocal") && detail.contains("允许传入连接"))
    XCTAssertGreaterThanOrEqual(firewall.checkedURLs.count, 2)
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
    var catalog = try CatalogFileStore(fileURL: catalogFileURL).load().catalog
    try catalog.remove(seeded.server)
    try CatalogFileStore(fileURL: catalogFileURL).save(CatalogDocument(catalog: catalog))

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

}

extension ProxyRuntimeControllerTests {
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

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)
    XCTAssertEqual(controller.state, .running)
    XCTAssertEqual(systemProxy.applied.count, 1)

    await controller.legacyImportDidCommit()

    XCTAssertEqual(controller.state, .off)
    XCTAssertEqual(controller.settings, importedSettings)
    XCTAssertEqual(controller.activeTargetID, seeded.server)
    XCTAssertEqual(systemProxy.restoreCount, 0, "Legacy 导入不能写入或恢复系统代理")
    XCTAssertEqual(systemProxy.applied.count, 1, "导入边界不应重新应用系统代理")
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

  func testUpdatingSettingsPersistsAndReactivatesTheRuntimeContract() async throws {
    let seeded = try makeSeededCatalog()
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)

    await controller.activate(seeded.server)
    await controller.setProxyEnabled(true)

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
      ["localhost", "127.0.0.1"])
  }

  private final class InMemoryProxySettingsStore: ProxySettingsStoring {
    var saved: ProxySettings?

    func load() throws -> ProxySettings {
      saved ?? ProxySettings()
    }

    func save(_ settings: ProxySettings) throws {
      saved = settings
    }

    func reset() throws {
      saved = nil
    }
  }
}
