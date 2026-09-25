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

/// 代理运行时控制器（spec #21 D2/D5/D7/D9，issue #27/#28/#60）：把激活状态机
/// 的产出接到「GUI → LaunchAgent → wrapper → sslocal」链路。决策全部在纯域
/// `ProxyRuntimePlan`，本类按序执行动作并负责健康呈现；GUI 退出不影响任何
/// 一侧（agent 由 launchd 持有，构造上成立）。
///
/// 两个用户意图相互独立（issue #60）：agent 意图（`settings.agentEnabled`，
/// 默认开启）驱动 LaunchAgent 注册与本地监听；系统代理意图
/// （`settings.systemProxyEnabled`，默认关闭）只在「agent 健康 + 模式具备
/// 可用出口」时写入系统设置，关闭只恢复 NG2 持有的系统设置。两个状态面
/// （`state` 与 `systemProxyState`）分开呈现，互不代替。
@MainActor
final class ProxyRuntimeController: ObservableObject {
  /// Agent（后台代理运行时）运行状态。系统代理结果不在此面呈现——它有
  /// 独立的 `SystemProxyControlState`。
  enum AgentRunState: Equatable {
    case off
    case starting
    case running
    /// 代理在本机运行，但主机地址态的入站被 macOS 防火墙拒绝。
    case firewallBlocked(FirewallBlockedFacts)
    /// 启动失败：携带点名端点与端口的事实（D8；端口语义细节 #30 接线）。
    case launchFailed(LaunchFailureFacts)
    /// 需要用户在系统设置-登录项中允许后台项。
    case requiresApproval
    /// 服务管理或运行时文件本身失败。
    case serviceFailed(ServiceFailureFacts)
  }

  /// 系统代理实际作用状态（issue #60）：意图持久化在
  /// `ProxySettings.systemProxyEnabled`，这里是 NG2 对系统设置的真实作用。
  enum SystemProxyControlState: Equatable {
    /// 意图关闭：NG2 不持有系统设置。
    case idle
    /// 意图开启，但 agent 未健康或模式缺少可用出口；条件恢复后随下次
    /// 收敛自动应用。
    case pending
    /// 已写入系统设置且持续持有。
    case applied
    /// 写入或恢复失败（typed；ownership 冲突报告而不强制覆盖）。
    case failed(SystemProxyFailureFacts)
  }

  @Published private(set) var state: AgentRunState = .off
  @Published private(set) var systemProxyState: SystemProxyControlState = .idle
  @Published private(set) var settings: ProxySettings
  @Published private(set) var pacURL: URL?
  /// 当前活动目标（菜单栏状态摘要与级联只读呈现用，issue #31）。machine 是
  /// 非发布值的普通结构体，代理关闭路径的激活动作不会触碰 state，菜单的
  /// 「目标」行依赖这里的独立发布保持实时。
  @Published private(set) var activeTargetID: NodeID?
  /// 最近一次激活预检在分组中跳过的服务器；仅记录 app 已知的本地阻塞原因。
  @Published private(set) var skippedServers: [SkippedServer] = []
  /// 最近一次激活拒绝或目标清除的点名原因。独立于运行状态呈现：agent 可
  /// 能仍在监听，激活失败不代表运行时停止（issue #60）。
  @Published private(set) var lastActivationFailure: ActivationFailure?
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

  /// Agent 开关意图（持久化事实；开关 UI 的绑定来源，issue #60）。
  var agentIntentEnabled: Bool { settings.agentEnabled }

  /// 系统代理开关意图（持久化事实；开关 UI 的绑定来源，issue #60）。
  var systemProxyIntentEnabled: Bool { settings.systemProxyEnabled }

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
    case .running, .firewallBlocked:
      isListening = true
    case .off, .starting, .launchFailed, .requiresApproval, .serviceFailed:
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

  /// 激活一个服务器或分组目标（目录 UI 工单复用入口）：持久化目标；agent
  /// 意图开启时立即把新档推到运行时。激活原子失败时目标与运行时完全不动
  /// （D3），点名原因进 `lastActivationFailure` 并返回 `.rejectedActivation`；
  /// 意外错误 throws 并进入 `serviceFailed`。
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
      lastActivationFailure = nil
      do {
        try activationFileStore.save(activeTargetID: target)
      } catch {
        state = .serviceFailed(.persistence)
        throw error
      }
      if settings.agentEnabled {
        await deploy(configuration.document)
      }
      return .activated(skippedInvalid: configuration.skippedServers.count)
    } catch let failure as ActivationFailure {
      lastActivationFailure = failure
      return .rejectedActivation
    } catch {
      state = .serviceFailed(.unknown)
      throw error
    }
  }

  /// Agent 开关（issue #60）：先持久化意图（显式关闭在 GUI 重启后仍生效），
  /// 再收敛运行时。持久化失败保留现状并点名，不静默偏离持久化事实。
  func setAgentEnabled(_ enabled: Bool) async {
    guard enabled != settings.agentEnabled else { return }
    var next = settings
    next.agentEnabled = enabled
    do {
      try settingsStore.save(next)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.persistence)
      return
    }
    settings = next
    if enabled {
      await convergeAgent()
    } else {
      await stopAgent()
    }
  }

  /// 系统代理开关（issue #60）：只写写/恢复 NG2 持有的系统设置；不注销
  /// agent、不停止本地 SOCKS/HTTP 监听。
  func setSystemProxyEnabled(_ enabled: Bool) async {
    guard enabled != settings.systemProxyEnabled else { return }
    var next = settings
    next.systemProxyEnabled = enabled
    do {
      try settingsStore.save(next)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.persistence)
      return
    }
    settings = next
    if enabled {
      await convergeSystemProxy()
    } else {
      systemProxyState = restoreSystemProxyOutcome()
    }
  }

  /// Changes the current mode without rebuilding the tunnel runtime. The mode
  /// only decides what the system proxy points at, so with the system proxy
  /// intent off nothing beyond persistence happens.
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
    guard settings.systemProxyEnabled else { return }
    guard state != .off, let document = lastDocument ?? runtimeFileStore.loadDocument() else {
      systemProxyState = .pending
      return
    }
    state = .starting
    await presentLaunchHealth(document)
  }

  /// GUI 启动重同步（D5「GUI 下次启动重新校验同步」；issue #60）：agent 意图
  /// 来自持久化设置——开启则自动注册/收敛 LaunchAgent 并部署（无活动目标时
  /// 以空服务器列表提供监听）；关闭则恢复系统代理后按停止协议收敛。GUI 崩溃
  /// 期间 agent 与 wrapper 均不受影响。
  func resyncOnLaunch() async {
    guard settings.agentEnabled else {
      await stopAgent()
      return
    }
    let catalog = catalogSnapshotReader.catalogSnapshot
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      await deploy(configuration.document)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
    case nil:
      await deployListeningWithoutTarget()
    }
  }

  // MARK: - 动作执行

  /// Agent 意图开启的收敛：注册态不是事实来源，意图才是——未注册也会注册
  /// （首次运行默认开启），已注册则重校验目标并部署。
  private func convergeAgent() async {
    let catalog = catalogSnapshotReader.catalogSnapshot
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      await deploy(configuration.document)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
    case nil:
      await deployListeningWithoutTarget()
    }
  }

  /// Agent 意图关闭的收敛（issue #60 验收次序）：先按 ownership 规则恢复
  /// NG2 持有的系统设置，再注销 agent 停止本地监听并清理运行时文件。
  private func stopAgent() async {
    let restoreError = restoreSystemProxyError()
    _ = await execute(.stop, document: nil)
    state = .off
    pacURL = nil
    lastDocument = nil
    skippedServers = []
    lastActivationFailure = nil
    systemProxyState = restoreError.map { .failed(systemProxyFacts(for: $0)) } ?? .idle
  }

  /// 无活动目标时 agent 仍提供本地监听（issue #60）：空服务器列表文档，
  /// SOCKS/HTTP/PAC 端点照常绑定；系统代理门禁会因缺少可用出口保持待应用。
  private func deployListeningWithoutTarget() async {
    let document = SslocalRuntimeDocument(
      servers: [],
      listen: settings.listen,
      timeout: settings.timeoutSeconds,
      verbose: settings.verboseLogging,
      pacUserRules: settings.pacUserRules)
    await deploy(document)
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
    _ = await execute(.stop, document: nil)
    pacURL = nil
    lastDocument = nil
    skippedServers = []
    state = .launchFailed(.unreadableSettings)
    await withdrawSystemProxyAfterEntryLoss()
  }

  /// 活动目标失效（issue #60）：清除并持久化 nil，点名原因独立呈现；agent
  /// 继续以空服务器列表监听；系统代理安全撤回（意图保留，条件恢复后自动
  /// 收敛），不悄悄选择其他服务器。
  private func handleCleared(_ failure: ActivationFailure) async {
    RuntimeLog.emit(.activationFailed(reason: String(describing: failure)))
    do {
      try activationFileStore.save(activeTargetID: nil)
    } catch {
      // 清目标失败不阻断收敛：下次重同步会再次收敛（目标已不在状态机中）。
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    }
    lastActivationFailure = failure
    skippedServers = []
    await withdrawSystemProxyAfterEntryLoss()
    if settings.agentEnabled {
      await deployListeningWithoutTarget()
    } else {
      // 会话内意图已被关闭的残余：按关闭语义收敛。
      _ = await execute(.stop, document: nil)
      state = .off
      pacURL = nil
      lastDocument = nil
    }
  }

}

// MARK: - 计划动作执行（同文件扩展：private 对本文件可见）

extension ProxyRuntimeController {
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

extension ProxyRuntimeController.AgentRunState {
  /// Agent 运行状态的「在跑」投影（状态摘要与诊断口径）：启动失败等未运行
  /// 态视为未跑。
  var isOn: Bool {
    switch self {
    case .off, .launchFailed, .serviceFailed:
      false
    case .starting, .running, .firewallBlocked, .requiresApproval:
      true
    }
  }
}

extension ProxyRuntimeController: Activating {}

extension ProxyRuntimeController {
  /// 目录提交协调器的生产适配入口（issue #40）：以刚提交的内存快照重展开，
  /// 不回读磁盘（磁盘仍是重启与跨进程恢复的权威来源）。agent 意图开启时
  /// 原子更新运行时；目标失效 → 清除目标但 agent 继续监听。返回结构化收敛
  /// 结果，健康检查耗时属于本调用的异步收敛阶段，不改变「目录已提交」的事实。
  func catalogDidCommit(snapshot catalog: ConfigurationCatalog) async -> RuntimeSyncOutcome {
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      guard settings.agentEnabled else {
        return .revalidated
      }
      await deploy(configuration.document)
      return Self.syncOutcome(
        agentState: state, systemProxyState: systemProxyState,
        skippedServers: configuration.skippedServers)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
      return .clearedAndStopped(failure)
    case nil:
      guard settings.agentEnabled else {
        return .revalidated
      }
      // 无活动目标：已在以空列表监听则不重走健康门（目录提交不该让状态闪回
      // starting）；否则补齐空监听。
      if state != .off, lastDocument?.servers.isEmpty == true {
        return Self.syncOutcome(
          agentState: state, systemProxyState: systemProxyState, skippedServers: [])
      }
      await deployListeningWithoutTarget()
      return Self.syncOutcome(
        agentState: state, systemProxyState: systemProxyState, skippedServers: [])
    }
  }

  /// 部署后的控制器状态 → 结构化收敛结果：健康通过（含防火墙受阻的运行态）
  /// 视为已收敛；系统代理写入失败携带点名细节，待应用不算目录收敛失败。
  private static func syncOutcome(
    agentState: AgentRunState, systemProxyState: SystemProxyControlState,
    skippedServers: [SkippedServer]
  ) -> RuntimeSyncOutcome {
    if case .failed(let facts) = systemProxyState {
      return .failed(failure: .systemProxy(facts))
    }
    switch agentState {
    case .running, .firewallBlocked:
      return .converged(skippedServers: skippedServers)
    case .launchFailed(let facts):
      return .failed(failure: .launch(facts))
    case .serviceFailed(let facts):
      return .failed(failure: .service(facts))
    case .requiresApproval, .off, .starting:
      return .failed(failure: nil)
    }
  }

  /// SettingsWorkflow 只需要知道 runtime 是否独立收敛，以及失败的安全 typed
  /// fact；它不消费控制器内部的 state machine。
  private func settingsRuntimeOutcome() -> SettingsRuntimeOutcome {
    if case .failed(let facts) = systemProxyState {
      return .failed(.systemProxy(facts))
    }
    switch state {
    case .off:
      return .notRunning
    case .running:
      return .converged
    case .firewallBlocked(let facts):
      return .failed(.firewallBlocked(facts))
    case .launchFailed(let facts):
      return .failed(.launch(facts))
    case .requiresApproval:
      return .failed(.requiresApproval)
    case .serviceFailed(let facts):
      return .failed(.service(facts))
    case .starting:
      return .failed(nil)
    }
  }

  /// Persists a fully validated settings snapshot and, when the agent is
  /// running, re-derives the same runtime path with the new snapshot.
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
      await deployListeningWithoutTarget()
    }
    return settingsRuntimeOutcome()
  }

  /// Restores factory defaults, removes the persisted snapshot and stops any
  /// active runtime before the next user action can use the defaults. Factory
  /// intents are agent on / system proxy off, so held system settings are
  /// restored and the agent stops until the next convergence.
  func resetPreferences() async throws -> SettingsRuntimeOutcome {
    try settingsStore.reset()
    settings = ProxySettings()
    listenSettingsUnreadable = false
    settingsUnreadable = false
    proxyMode = .pac
    lastActivationFailure = nil
    await stopAgent()
    if case .failed(let facts) = systemProxyState {
      return .failed(.systemProxy(facts))
    }
    return .stopped
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
    lastActivationFailure = nil
    // 导入边界不触碰 SystemConfiguration（既有不变量），系统代理状态面同
    // 样不动：它呈现的是系统设置的真实作用，不由导入改写。

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
  /// GET PAC endpoint；主机态额外查询应用防火墙拒绝记录。任一端点超时都点名
  /// 呈现。健康通过后系统代理按意图与门禁收敛（不在此无条件写入）。
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
          await withdrawSystemProxyAfterEntryLoss()
          return
        }
        pacOutcome = await pacProbe.probe(url: healthURL, timeout: 1.5)
        if pacOutcome == .reachable {
          guard generation == flowGeneration else { return }
          pacURL = document.pac.publicURL
          await presentFirewallStatus(for: document)
          await convergeSystemProxy()
          return
        }
      }
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    if generation != flowGeneration { return }
    if let endpointFailure {
      presentEndpointFailure(endpointFailure)
    } else {
      let pacFailure: RuntimeEndpointFailure
      switch pacOutcome {
      case .reachable:
        pacFailure = .unknown
      case .failed:
        pacFailure = runtimeEndpointFailure(from: pacOutcome)
      }
      state = .launchFailed(.pacEndpoint(port: document.pac.port, cause: pacFailure))
    }
    await withdrawSystemProxyAfterEntryLoss()
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

  // MARK: - 系统代理门禁（issue #60）

  /// 系统代理收敛：意图开启 + agent 健康 + 所选模式具备可用出口（活动目标
  /// 通过本地预检）才写入；否则保持待应用，条件恢复后随下次收敛自动应用。
  /// 意图关闭时不做任何事（呈现面保持 idle/既有失败态）。
  private func convergeSystemProxy() async {
    guard settings.systemProxyEnabled else { return }
    guard systemProxyExitAvailable, let document = lastDocument else {
      systemProxyState = .pending
      return
    }
    do {
      let configuration = try proxyMode.systemProxyConfiguration(
        for: document, exceptions: settings.proxyExceptionList)
      try systemProxy.apply(configuration)
      systemProxyState = .applied
    } catch {
      systemProxyState = .failed(systemProxyFacts(for: error))
    }
  }

  /// 出口可用 = agent 入站健康（回环入口可用，含防火墙仅阻主机态的情形）
  /// 且存在活动目标（模式所需出口）。远端网络可达性不在承诺范围内。
  private var systemProxyExitAvailable: Bool {
    switch state {
    case .running, .firewallBlocked:
      return activeTargetID != nil
    case .off, .starting, .launchFailed, .requiresApproval, .serviceFailed:
      return false
    }
  }

  /// agent 入站不可用（启动失败、目标清除、监听设置不可读）时的安全撤回：
  /// 尽力恢复 NG2 持有的系统设置；意图保留为待应用，条件恢复后自动收敛。
  /// 恢复失败以 typed 呈现——系统设置仍被 NG2 持有时用户必须知道。
  private func withdrawSystemProxyAfterEntryLoss() async {
    if let error = restoreSystemProxyError() {
      systemProxyState = .failed(systemProxyFacts(for: error))
      return
    }
    systemProxyState = settings.systemProxyEnabled ? .pending : .idle
  }

  /// 恢复 NG2 持有的系统设置；成功 → `.idle`，失败 → typed 失败。
  private func restoreSystemProxyOutcome() -> SystemProxyControlState {
    if let error = restoreSystemProxyError() {
      return .failed(systemProxyFacts(for: error))
    }
    return .idle
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
