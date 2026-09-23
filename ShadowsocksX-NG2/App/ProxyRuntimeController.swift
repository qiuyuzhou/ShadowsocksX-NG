import Foundation
import SwiftUI

/// 端点探测缝：注入以便控制器单测（真实探测走 EndpointHealthProbe）。
protocol EndpointProbing: Sendable {
  func probe(host: String, port: Int, timeout: TimeInterval) -> EndpointHealthProbe.Outcome
}

struct SystemEndpointProbe: EndpointProbing {
  func probe(host: String, port: Int, timeout: TimeInterval) -> EndpointHealthProbe.Outcome {
    EndpointHealthProbe.probe(host: host, port: port, timeout: timeout)
  }
}

/// 代理运行时控制器（spec #21 D2/D5/D7/D9，issue #27/#28）：把激活状态机的产出接到
/// 「GUI → LaunchAgent → wrapper → sslocal」链路。决策全部在纯域
/// `ProxyRuntimePlan`，本类按序执行动作并负责健康呈现；GUI 退出不影响任何
/// 一侧（agent 由 launchd 持有，构造上成立）。
@MainActor
final class ProxyRuntimeController: ObservableObject {
  enum ProxyState: Equatable {
    case off
    case starting
    case running
    /// 代理在本机运行，但主机地址态的入站被 macOS 防火墙拒绝。
    case firewallBlocked(FirewallBlockedFacts)
    /// 启动失败：携带点名端点与端口的事实（D8；端口语义细节 #30 接线）。
    case launchFailed(LaunchFailureFacts)
    /// 激活失败或活动目标清除（无静默回退族的呈现面）。
    case activationFailed(ActivationFailure)
    /// 需要用户在系统设置-登录项中允许后台项。
    case requiresApproval
    /// 服务管理或运行时文件本身失败。
    case serviceFailed(ServiceFailureFacts)
    /// 运行时健康，但系统代理未能应用或恢复。
    case systemProxyFailed(SystemProxyFailureFacts)
  }

  @Published private(set) var state: ProxyState = .off
  @Published private(set) var settings: ProxySettings
  @Published private(set) var pacURL: URL?
  /// 当前活动目标（菜单栏状态摘要与级联只读呈现用，issue #31）。machine 是
  /// 非发布值的普通结构体，代理关闭路径的激活动作不会触碰 state，菜单的
  /// 「目标」行依赖这里的独立发布保持实时。
  @Published private(set) var activeTargetID: NodeID?
  /// 最近一次激活预检在分组中跳过的服务器；仅记录 app 已知的本地阻塞原因。
  @Published private(set) var skippedServers: [SkippedServer] = []
  private(set) var machine: ActivationStateMachine

  private let catalogSnapshotReader: RuntimeCatalogSnapshotReading
  private let activationFileStore: ActivationStateFileStore
  private let runtimeFileStore: RuntimeFileStore
  private let credentials: CredentialStoring
  private let plugins: ManagedPluginProviding
  private let settingsStore: ProxySettingsStoring
  /// 监听设置不可读时的点名原因（D8「任何路径不静默改端口」）；非 nil 时
  /// 设置只是占位出厂默认，禁止部署（见 `deploy`）。
  private var listenSettingsUnreadable: Bool
  /// 新版偏好不可读时同样禁止部署，不以出厂端口静默替代用户配置。
  private var settingsUnreadable: Bool
  private let agent: LaunchAgentControlling
  private let probe: EndpointProbing
  private let pacProbe: PACHealthProbing
  private let systemProxy: SystemProxyControlling
  private let firewallChecker: FirewallStatusChecking
  private let firewallExecutableURLs: [URL]
  private let firewallPollIntervalNanoseconds: UInt64
  /// 信号发送缝（默认 kill），单测观测 SIGUSR1 投递。
  private let sendSignal: @Sendable (Int32, Int32) -> Int32
  /// 并发流代际：停止请求可使进行中的启动探测立即失效。
  private var flowGeneration = 0
  private var lastDocument: SslocalRuntimeDocument?
  private var firewallObservationTask: Task<Void, Never>?

  @Published private(set) var proxyMode: ProxyMode

  init(
    catalogSnapshotReader: RuntimeCatalogSnapshotReading,
    activationFileStore: ActivationStateFileStore = ActivationStateFileStore(
      fileURL: ActivationStateFileStore.defaultFileURL()),
    runtimeFileStore: RuntimeFileStore = RuntimeFileStore(),
    credentials: CredentialStoring = KeychainCredentialStore(),
    plugins: ManagedPluginProviding = BundleManagedPluginProvider(),
    listenRestore: RestoredListenSettings = ListenSettingsFileStore.restored(),
    settingsStore: ProxySettingsStoring = ProxySettingsFileStore(),
    settingsRestore: RestoredProxySettings? = nil,
    agent: LaunchAgentControlling = SMAppLaunchAgentService(),
    probe: EndpointProbing = SystemEndpointProbe(),
    pacProbe: PACHealthProbing = SystemPACHealthProbe(),
    systemProxy: SystemProxyControlling = SystemConfigurationProxyController(),
    proxyMode: ProxyMode? = nil,
    firewallChecker: FirewallStatusChecking = SocketFilterFirewallChecker(),
    firewallExecutableURLs: [URL]? = nil,
    firewallPollIntervalNanoseconds: UInt64 = 2_000_000_000,
    sendSignal: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) }
  ) {
    self.catalogSnapshotReader = catalogSnapshotReader
    self.activationFileStore = activationFileStore
    self.runtimeFileStore = runtimeFileStore
    self.credentials = credentials
    self.plugins = plugins
    self.settingsStore = settingsStore
    let restoredSettings =
      settingsRestore
      ?? RestoredProxySettings(
        settings: ProxySettings(listen: listenRestore.settings),
        unreadableError: listenRestore.unreadableError.map {
          .legacyListenSettings($0)
        })
    settings = restoredSettings.settings
    listenSettingsUnreadable =
      settingsRestore == nil && listenRestore.unreadableError != nil
    settingsUnreadable = restoredSettings.unreadableError != nil
    self.agent = agent
    self.probe = probe
    self.pacProbe = pacProbe
    self.systemProxy = systemProxy
    self.firewallChecker = firewallChecker
    self.firewallExecutableURLs = firewallExecutableURLs ?? Self.defaultFirewallExecutableURLs
    self.firewallPollIntervalNanoseconds = firewallPollIntervalNanoseconds
    self.sendSignal = sendSignal
    let persistedTarget = try? activationFileStore.loadActiveTargetID()
    machine = ActivationStateMachine(activeTargetID: persistedTarget)
    activeTargetID = machine.activeTargetID
    self.proxyMode = proxyMode ?? Self.makeProxyMode(from: restoredSettings.settings)
  }

  var isActiveTargetPresent: Bool { machine.activeTargetID != nil }

  /// Stable app-facing projection for status-menu presentation. The menu does
  /// not depend on this controller's nested state representation.
  var runtimeFacts: ProxyRuntimeFacts {
    ProxyRuntimeFacts(state: state)
  }

  private static var defaultFirewallExecutableURLs: [URL] {
    let bundle = Bundle.main.bundleURL
    return [
      bundle.appendingPathComponent("Contents/MacOS/ShadowsocksX-NG2Agent"),
      bundle.appendingPathComponent("Contents/Helpers/sslocal"),
    ]
  }

  /// 诊断只读面（issue #34）：当前监听设置；监听地址在导出中只以回环/非回环
  /// 两态呈现（D7）。
  var listenSettings: SslocalListenSettings { settings.listen }

  /// 当前已部署 runtime 的完整监听身份。已停止或启动失败时没有有效的
  /// runtime 例外，不能拿最后一次设置快照冒充仍在监听。
  var effectiveRuntimeListenFacts: RuntimeListenFacts? {
    let isListening: Bool
    switch state {
    case .running, .firewallBlocked, .systemProxyFailed:
      isListening = true
    case .off, .starting, .launchFailed, .activationFailed, .requiresApproval, .serviceFailed:
      isListening = false
    }
    guard isListening, let lastDocument else { return nil }
    return RuntimeListenFacts(document: lastDocument)
  }

  /// 运行时契约的脱敏摘要（数量与协议元数据，D5）；契约缺失或无效返回 nil。
  /// 诊断导出不读契约内容，只携带此摘要。
  func runtimeDocumentSummary() -> String? {
    runtimeFileStore.loadDocument().map { Redactor.documentSummary($0) }
  }

  // MARK: - 用户意图

  /// 激活一个服务器或分组目标（目录 UI 工单复用入口）：持久化目标；代理
  /// 开启时立即把新档推到运行时。激活原子失败时状态完全不动（D3），返回
  /// `.rejectedActivation`；意外错误 throws 并进入 `serviceFailed`。
  @discardableResult
  func activate(_ target: NodeID) async throws -> ActivationCommandOutcome {
    let catalog = catalogSnapshotReader.catalogSnapshot
    do {
      let configuration = try machine.activate(
        target, in: catalog, credentials: credentials, plugins: plugins, listen: settings.listen,
        timeout: settings.timeoutSeconds, verbose: settings.verboseLogging,
        pacUserRules: settings.pacUserRules)
      activeTargetID = target
      skippedServers = configuration.skippedServers
      do {
        try activationFileStore.save(activeTargetID: target)
      } catch {
        state = .serviceFailed(.persistence)
        throw error
      }
      if state != .off {
        await deploy(configuration.document)
      }
      return .activated(skippedInvalid: configuration.skippedServers.count)
    } catch let failure as ActivationFailure {
      state = .activationFailed(failure)
      return .rejectedActivation
    } catch {
      state = .serviceFailed(.unknown)
      throw error
    }
  }

  /// 代理开关。
  func setProxyEnabled(_ enabled: Bool) async {
    if enabled {
      await enable()
    } else {
      let restoreError: Error?
      do {
        try systemProxy.restore()
        restoreError = nil
      } catch {
        restoreError = error
      }
      _ = await execute(.stop, document: nil)
      if let restoreError {
        state = .systemProxyFailed(systemProxyFacts(for: restoreError))
      } else {
        state = .off
      }
      pacURL = nil
      lastDocument = nil
    }
  }

  /// Changes the current mode without rebuilding the tunnel runtime. Every
  /// supported mode reuses the same endpoint health gate before writing system
  /// settings.
  /// The choice persists with the settings snapshot first, so a GUI restart
  /// restores it; a persistence failure keeps the previous mode in force and
  /// names the reason instead of switching silently.
  func setProxyMode(_ mode: ProxyMode) async {
    guard ProxyMode.availableModes.contains(mode) else { return }
    guard mode != proxyMode else { return }
    var next = settings
    next.preferredMode = mode.kind
    do {
      try settingsStore.save(next)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.persistence)
      return
    }
    settings = next
    proxyMode = mode
    guard state != .off, let document = lastDocument ?? runtimeFileStore.loadDocument() else {
      return
    }

    state = .starting
    await presentLaunchHealth(document)
  }

  /// GUI 启动重同步（D5「GUI 下次启动重新校验同步」）：注册态是代理意图的
  /// 事实来源——注册过即视为开启并重校验；随后与磁盘契约对齐（相同内容跳
  /// 过写入）。GUI 崩溃期间 agent 与 wrapper 均不受影响。
  func resyncOnLaunch() async {
    let catalog = catalogSnapshotReader.catalogSnapshot
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      let status = agent.status
      if status == .registered || status == .requiresApproval {
        await deploy(configuration.document)
      } else {
        // 未注册但可能残留运行时文件（上次异常退出）：清理残留，保持停止态。
        runtimeFileStore.deleteRuntimeFiles()
        RuntimeLog.emit(.runtimeFilesDeleted)
        let restoreError = restoreSystemProxyError()
        state =
          restoreError.map {
            .systemProxyFailed(systemProxyFacts(for: $0))
          } ?? .off
        pacURL = nil
      }
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
    case nil:
      // 无活动目标：只剩清理残留（计划层只在已注册时注销）。
      let restoreError = restoreSystemProxyError()
      _ = await execute(.stop, document: nil)
      state =
        restoreError.map {
          .systemProxyFailed(systemProxyFacts(for: $0))
        } ?? .off
      pacURL = nil
    }
  }

  // MARK: - 动作执行

  private func enable() async {
    guard machine.activeTargetID != nil else {
      presentNoActiveTarget()
      return
    }
    let catalog = catalogSnapshotReader.catalogSnapshot
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      await deploy(configuration.document)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
    case nil:
      presentNoActiveTarget()
    }
  }

  private func presentNoActiveTarget() {
    RuntimeLog.emit(.activationFailed(reason: "no active target"))
    state = .activationFailed(.noActiveTarget)
  }

  /// 把「运行定义档」意图推到运行时：计划动作 → 顺序执行 → 端点健康呈现。
  private func deploy(_ document: SslocalRuntimeDocument) async {
    if listenSettingsUnreadable || settingsUnreadable {
      await refuseDeployForUnreadableListenSettings()
      return
    }
    pacURL = nil
    lastDocument = document
    if await execute(.run(document), document: document) {
      state = .starting
      await presentLaunchHealth(document)
    }
  }

  /// D8「任何路径不静默改端口」：监听设置不可读时以占位出厂端口部署等于
  /// 系统擅自改端口——停止运行时并点名呈现，等用户在设置区修复（#33 接线）。
  private func refuseDeployForUnreadableListenSettings() async {
    RuntimeLog.emit(.activationFailed(reason: "listen settings unreadable"))
    let restoreError = restoreSystemProxyError()
    _ = await execute(.stop, document: nil)
    pacURL = nil
    lastDocument = nil
    skippedServers = []
    if let restoreError {
      state = .systemProxyFailed(systemProxyFacts(for: restoreError))
    } else {
      state = .launchFailed(.unreadableSettings)
    }
  }

  private func handleCleared(_ failure: ActivationFailure) async {
    RuntimeLog.emit(.activationFailed(reason: String(describing: failure)))
    do {
      try activationFileStore.save(activeTargetID: nil)
    } catch {
      // 清目标失败不阻断停止：下次重同步会再次收敛（目标已不在状态机中）。
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    }
    let restoreError = restoreSystemProxyError()
    _ = await execute(.stop, document: nil)
    pacURL = nil
    lastDocument = nil
    skippedServers = []
    if let restoreError {
      state = .systemProxyFailed(systemProxyFacts(for: restoreError))
    } else {
      state = .activationFailed(failure)
    }
  }

  /// 按计划顺序执行动作；返回 false 表示中途失败、状态已呈现（后续动作与
  /// 健康探测都不应继续）。
  private func execute(_ intent: RuntimeIntent, document: SslocalRuntimeDocument?) async -> Bool {
    cancelFirewallObservation()
    flowGeneration += 1
    let actions = ProxyRuntimePlan.actions(
      intent: intent,
      agentStatus: agent.status,
      wrapper: wrapperState(),
      contractOnDisk: runtimeFileStore.readData())
    if case .run = intent, actions.isEmpty {
      RuntimeLog.emit(.contractUnchanged)
    }
    for action in actions {
      guard await perform(action, document: document) else { return false }
    }
    return true
  }

  /// 执行单个动作；返回 false 表示应终止后续动作（状态已呈现）。
  private func perform(_ action: RuntimeAction, document: SslocalRuntimeDocument?) async -> Bool {
    switch action {
    case .writeContract:
      guard let document else {
        state = .serviceFailed(.missingDocument)
        return false
      }
      do {
        try runtimeFileStore.write(document)
        RuntimeLog.emit(.contractWritten(serverCount: document.servers.count))
      } catch {
        state = .serviceFailed(.runtimeFile)
        return false
      }
    case .registerAgent:
      do {
        try agent.register()
      } catch {
        RuntimeLog.emit(.agentRegisterFailed(detail: describe(error)))
        if agent.status == .requiresApproval {
          // 注册请求已被系统接收，等待用户在登录项中批准。
          state = .requiresApproval
          return false
        }
        if agent.status != .registered {
          state = .serviceFailed(.agent)
          return false
        }
        // 注册与状态读取之间的竞态：已注册即达意图，不视为失败。
      }
      RuntimeLog.emit(.agentRegistered)
      if agent.status == .requiresApproval {
        state = .requiresApproval
        return false
      }
    case .unregisterAgent:
      do {
        try agent.unregister()
      } catch {
        // 未注册竞态可忽略；其余错误记录后继续清理（尽力而为）。
        RuntimeLog.emit(.agentUnregisterFailed(detail: describe(error)))
      }
      RuntimeLog.emit(.agentUnregistered)
      await waitForWrapperExit()
    case .signalReload(let pid):
      _ = sendSignal(pid, SIGUSR1)
    case .deleteRuntimeFiles:
      runtimeFileStore.deleteRuntimeFiles()
      RuntimeLog.emit(.runtimeFilesDeleted)
    }
    return true
  }
}

extension ProxyRuntimeController.ProxyState {
  /// 代理开关的当前意图（菜单开关与设置工作流共用的同一判定）：启动失败等
  /// 未运行态视为未开——两个入口的下一步动作都是「启动」。
  var isOn: Bool {
    switch self {
    case .off, .launchFailed, .activationFailed, .serviceFailed:
      false
    case .starting, .running, .firewallBlocked, .requiresApproval, .systemProxyFailed:
      true
    }
  }
}

extension ProxyRuntimeController: Activating {}

extension ProxyRuntimeController {
  /// 目录提交协调器的生产适配入口（issue #40）：以刚提交的内存快照重展开，
  /// 不回读磁盘（磁盘仍是重启与跨进程恢复的权威来源）。有效非空且代理开启
  /// → 原子更新运行时；目标失效 → 清除目标并停止代理。返回结构化收敛结果，
  /// 健康检查耗时属于本调用的异步收敛阶段，不改变「目录已提交」的事实。
  func catalogDidCommit(snapshot catalog: ConfigurationCatalog) async -> RuntimeSyncOutcome {
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      guard state != .off else {
        return .revalidated
      }
      await deploy(configuration.document)
      return Self.syncOutcome(for: state, skippedServers: configuration.skippedServers)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
      return .clearedAndStopped(failure)
    case nil:
      return .revalidated
    }
  }

  /// 部署后的控制器状态 → 结构化收敛结果：健康通过（含防火墙受阻的运行态）
  /// 视为已收敛；启动、服务、系统代理与激活拒绝都视为未收敛并携带点名细节。
  private static func syncOutcome(
    for state: ProxyState, skippedServers: [SkippedServer]
  ) -> RuntimeSyncOutcome {
    switch state {
    case .running, .firewallBlocked:
      .converged(skippedServers: skippedServers)
    case .launchFailed(let facts):
      .failed(failure: .launch(facts))
    case .serviceFailed(let facts):
      .failed(failure: .service(facts))
    case .systemProxyFailed(let facts):
      .failed(failure: .systemProxy(facts))
    case .activationFailed(let failure):
      .failed(failure: .activation(failure))
    case .requiresApproval, .off, .starting:
      .failed(failure: nil)
    }
  }

  /// SettingsWorkflow 只需要知道 runtime 是否独立收敛，以及失败的安全 typed
  /// fact；它不消费控制器内部的 state machine。
  private func settingsRuntimeOutcome() -> SettingsRuntimeOutcome {
    switch state {
    case .off:
      return .notRunning
    case .running:
      return .converged
    case .firewallBlocked(let facts):
      return .failed(.firewallBlocked(facts))
    case .launchFailed(let facts):
      return .failed(.launch(facts))
    case .activationFailed(let failure):
      return .failed(.activation(failure))
    case .requiresApproval:
      return .failed(.requiresApproval)
    case .serviceFailed(let facts):
      return .failed(.service(facts))
    case .systemProxyFailed(let facts):
      return .failed(.systemProxy(facts))
    case .starting:
      return .failed(nil)
    }
  }

  /// Persists a fully validated settings snapshot and, when the proxy is
  /// active, re-derives the same runtime path with the new snapshot.
  func updateSettings(_ proposed: ProxySettings) async throws -> SettingsRuntimeOutcome {
    let catalog = catalogSnapshotReader.catalogSnapshot
    try settingsStore.save(proposed)
    settings = proposed
    listenSettingsUnreadable = false
    settingsUnreadable = false
    guard state != .off else { return .notRunning }
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      await deploy(configuration.document)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
    case nil:
      break
    }
    return settingsRuntimeOutcome()
  }

  /// Restores factory defaults, removes the persisted snapshot and stops any
  /// active runtime before the next user action can use the defaults.
  func resetPreferences() async throws -> SettingsRuntimeOutcome {
    try settingsStore.reset()
    settings = ProxySettings()
    listenSettingsUnreadable = false
    settingsUnreadable = false
    proxyMode = .pac
    if state != .off {
      await setProxyEnabled(false)
      return state == .off ? .stopped : settingsRuntimeOutcome()
    }
    return .notRunning
  }

  /// Applies the post-import 2.0 runtime boundary without touching
  /// SystemConfiguration. Importing data leaves the user's system proxy
  /// dictionary untouched; any currently running 2.0 runtime is stopped and
  /// the existing 2.0 target/settings are reloaded.
  func legacyImportDidCommit() async {
    cancelFirewallObservation()
    flowGeneration += 1
    _ = await execute(.stop, document: nil)
    state = .off
    pacURL = nil
    lastDocument = nil
    skippedServers = []

    if let restored = try? settingsStore.load() {
      settings = restored
      settingsUnreadable = false
      listenSettingsUnreadable = false
      proxyMode = Self.makeProxyMode(from: restored)
    }
    let persistedTarget = try? activationFileStore.loadActiveTargetID()
    machine = ActivationStateMachine(activeTargetID: persistedTarget ?? nil)
    activeTargetID = machine.activeTargetID
  }
}

extension ProxyRuntimeController {
  private struct LocalEndpointFailure {
    let local: SslocalLocalDocument
    let host: String
    let outcome: EndpointHealthProbe.Outcome
  }

  /// 启动健康呈现（D2/D7/D8）：先确认 sslocal 的 SOCKS/HTTP TCP 绑定，再
  /// GET PAC endpoint；主机态额外查询应用防火墙拒绝记录。任一端点超时都点名呈现。
  private func presentLaunchHealth(_ document: SslocalRuntimeDocument) async {
    let generation = flowGeneration
    let deadline = Date().addingTimeInterval(15)
    var endpointFailure: LocalEndpointFailure?
    var pacOutcome = PACHealthOutcome.failed(detail: "尚未探测")
    while Date() < deadline {
      if generation != flowGeneration { return }
      endpointFailure = await unhealthyLocalEndpoint(in: document)
      if endpointFailure == nil {
        guard let healthURL = document.pac.healthURL else {
          state = .launchFailed(
            .pacEndpoint(port: document.pac.port, cause: .invalidResponse))
          return
        }
        pacOutcome = await pacProbe.probe(url: healthURL, timeout: 1.5)
        if pacOutcome == .reachable {
          guard generation == flowGeneration else { return }
          pacURL = document.pac.publicURL
          guard applySystemProxy(for: document) else { return }
          await presentFirewallStatus(for: document)
          return
        }
      }
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    if generation != flowGeneration { return }
    if let endpointFailure {
      presentEndpointFailure(endpointFailure)
      return
    }
    let pacFailure: RuntimeEndpointFailure
    switch pacOutcome {
    case .reachable:
      pacFailure = .unknown
    case .failed:
      pacFailure = runtimeEndpointFailure(from: pacOutcome)
    }
    state = .launchFailed(.pacEndpoint(port: document.pac.port, cause: pacFailure))
  }

  private func unhealthyLocalEndpoint(
    in document: SslocalRuntimeDocument
  ) async -> LocalEndpointFailure? {
    for local in document.locals {
      let outcome = await probeAsync(
        host: local.probeHost, port: local.localPort, timeout: 1.5)
      if outcome != .reachable {
        return LocalEndpointFailure(local: local, host: local.probeHost, outcome: outcome)
      }
    }
    return nil
  }

  private func presentEndpointFailure(_ failure: LocalEndpointFailure) {
    let detail: String
    let cause: RuntimeEndpointFailure
    switch failure.outcome {
    case .reachable:
      detail = "已连通"
      cause = .unknown
    case .refused(let reason):
      detail = reason
      cause = .refused
    case .timedOut:
      detail = "连接超时"
      cause = .timedOut
    }
    RuntimeLog.emit(
      .endpointProbeFailed(
        host: failure.host, port: failure.local.localPort, detail: detail))
    let endpointName = failure.local.inboundProtocol.uppercased()
    state = .launchFailed(
      .localEndpoint(
        endpoint: endpointName, host: failure.host, port: failure.local.localPort, cause: cause))
  }

  private func presentFirewallStatus(for document: SslocalRuntimeDocument) async {
    guard document.pac.listenScope == .host else {
      state = .running
      return
    }
    if let blocked = await blockedFirewallExecutable() {
      presentFirewallBlocked(blocked)
      return
    }
    state = .running
    observeFirewall(generation: flowGeneration)
  }

  private func blockedFirewallExecutable() async -> URL? {
    for executableURL in firewallExecutableURLs {
      let status = await firewallStatus(for: executableURL)
      if status == .blocked { return executableURL }
    }
    return nil
  }

  private func presentFirewallBlocked(_ executableURL: URL) {
    let name = executableURL.lastPathComponent
    state = .firewallBlocked(FirewallBlockedFacts(executableName: name))
  }

  private func observeFirewall(generation: Int) {
    firewallObservationTask?.cancel()
    let interval = firewallPollIntervalNanoseconds
    firewallObservationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        guard !Task.isCancelled, let self, generation == flowGeneration else { return }
        if let blocked = await blockedFirewallExecutable() {
          presentFirewallBlocked(blocked)
          firewallObservationTask = nil
          return
        }
      }
    }
  }

  private func cancelFirewallObservation() {
    firewallObservationTask?.cancel()
    firewallObservationTask = nil
  }

  private func firewallStatus(for executableURL: URL) async -> FirewallBlockStatus {
    let checker = firewallChecker
    return await Task.detached(priority: .utility) {
      checker.status(for: executableURL)
    }.value
  }

  private func probeAsync(
    host: String, port: Int, timeout: TimeInterval
  ) async -> EndpointHealthProbe.Outcome {
    let probe = probe
    return await Task.detached(priority: .utility) {
      probe.probe(host: host, port: port, timeout: timeout)
    }.value
  }

  /// 显式停止协议次序（D2）：注销（SIGTERM wrapper → wrapper 停 sslocal 并
  /// 等待）完成后才允许后续删文件动作。最多等 5 秒，超时也继续（launchd 会
  /// 兜底结束进程）。
  private func waitForWrapperExit() async {
    let deadline = Date().addingTimeInterval(5)
    while wrapperState() != .notRunning && Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  private func wrapperState() -> WrapperProcessState {
    guard
      let data = try? Data(contentsOf: runtimeFileStore.pidFileURL),
      let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      let pid = Int32(text)
    else { return .notRunning }
    guard sendSignal(pid, 0) == 0 else { return .notRunning }
    return .running(pid: pid)
  }

  // MARK: - 目录同步

  /// Re-expands one command-start snapshot; a concurrently published catalog
  /// is intentionally observed by the next command, not halfway through this one.
  private func reexpand(in catalog: ConfigurationCatalog) -> ActivationEffect? {
    let effect = machine.catalogDidCommit(
      catalog, credentials: credentials, plugins: plugins, listen: settings.listen,
      timeout: settings.timeoutSeconds, verbose: settings.verboseLogging,
      pacUserRules: settings.pacUserRules)
    activeTargetID = machine.activeTargetID
    switch effect {
    case .deployed(let configuration):
      skippedServers = configuration.skippedServers
    case .clearedAndStopped:
      skippedServers = []
    case nil:
      break
    }
    return effect
  }

  private func describe(_ error: Error) -> String {
    String(describing: error)
  }

  private func applySystemProxy(for document: SslocalRuntimeDocument) -> Bool {
    do {
      let configuration = try proxyMode.systemProxyConfiguration(
        for: document, exceptions: settings.proxyExceptionList)
      try systemProxy.apply(configuration)
      return true
    } catch {
      state = .systemProxyFailed(systemProxyFacts(for: error))
      return false
    }
  }

  private func restoreSystemProxyError() -> Error? {
    do {
      try systemProxy.restore()
      return nil
    } catch {
      return error
    }
  }

  private func systemProxyFacts(for error: Error) -> SystemProxyFailureFacts {
    if let error = error as? SystemProxyError {
      return Self.systemProxyFacts(for: error)
    }
    if let error = error as? ProxyModeError {
      return .mode(error)
    }
    return .unknown
  }

  private static func systemProxyFacts(
    for error: SystemProxyError
  ) -> SystemProxyFailureFacts {
    switch error {
    case .authorizationFailed: return .operation(.authorizationFailed)
    case .preferencesUnavailable: return .operation(.preferencesUnavailable)
    case .preferencesBusy: return .operation(.preferencesBusy)
    case .noCurrentNetworkSet: return .operation(.noCurrentNetworkSet)
    case .noProxyServices: return .operation(.noProxyServices)
    case .unreadableService: return .operation(.unreadableService)
    case .ownershipConflict: return .ownershipConflict
    case .invalidStoredConfiguration: return .operation(.invalidStoredConfiguration)
    case .cannotWriteService: return .operation(.cannotWriteService)
    case .commitFailed: return .operation(.commitFailed)
    case .applyFailed: return .operation(.applyFailed)
    case .ownershipStoreFailed: return .operation(.ownershipStoreFailed)
    }
  }

  private func runtimeEndpointFailure(from outcome: EndpointHealthProbe.Outcome)
    -> RuntimeEndpointFailure
  {
    switch outcome {
    case .reachable: return .unknown
    case .refused: return .refused
    case .timedOut: return .timedOut
    }
  }

  private func runtimeEndpointFailure(from outcome: PACHealthOutcome)
    -> RuntimeEndpointFailure
  {
    switch outcome {
    case .reachable: return .unknown
    case .failed(let detail):
      let normalized = detail.lowercased()
      if normalized.contains("timeout") || normalized.contains("timedout") {
        return .timedOut
      }
      if normalized.contains("http") || normalized.contains("mime") || normalized.contains("内容") {
        return .invalidResponse
      }
      return .unknown
    }
  }
}

extension ProxyRuntimeController {
  fileprivate static func makeProxyMode(from settings: ProxySettings) -> ProxyMode {
    ProxyMode.availableModes.first { $0.kind == settings.preferredMode } ?? .pac
  }
}
