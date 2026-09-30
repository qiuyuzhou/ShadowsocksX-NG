import Foundation

/// 代理运行时控制器（spec #21 D2/D5/D7/D9，issue #27/#28/#60/#71）：把激活状态机
/// 的产出接到「GUI → LaunchAgent → wrapper → sslocal」链路。launchd/契约动作
/// 序列在纯域 `ProxyRuntimePlan`，本类按序执行、负责健康呈现与系统代理门禁
/// 收敛（issue #60：意图持久化先行；issue #71：系统代理写入经特权 helper，
/// 清理只随意图 on→off 迁移发生）；GUI 退出不会停止 launchd 持有的 agent，
/// 网络变化观察则随 GUI 退出。
///
/// 两个用户意图相互独立（issue #60）：agent 意图（`settings.agentEnabled`，
/// 默认开启）驱动 LaunchAgent 注册与本地监听；系统代理意图
/// （`settings.systemProxyEnabled`，默认关闭）只在「helper 可用 + agent 健康
/// + 模式具备可用出口」时经 helper 应用系统设置。清理是意图 on→off 迁移的
/// 副作用：开关直接关闭，或关闭 agent 时级联关闭仍开启的系统代理意图；
/// 启动、健康门禁、目标失效与被动网络事件永不清理（issue #71）。两个状态面
/// （`state` 与 `systemProxyState`）分开呈现，互不代替。
///
/// 命令面、设置/目录同步、防火墙与系统代理门禁、只读事实投影分别在
/// `+Commands` / `+SettingsSync` / `+SystemProxyGate` / `+Facts` 扩展文件；
/// 本文件只保留状态、依赖缝与构造。
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
  /// 清理失败（typed）也在此呈现；清理只由意图 on→off 迁移触发（issue #71）。
  enum SystemProxyControlState: Equatable {
    /// 意图关闭：系统代理清理完成。
    case idle
    /// 意图开启，但 helper 不可用/待批准、agent 未健康或模式缺少可用出口；
    /// 条件恢复后随下次收敛自动应用，系统设置保持原样。
    case pending
    /// 已应用系统代理配置。
    case applied
    /// 应用或清理失败（typed）。
    case failed(SystemProxyFailureFacts)
  }

  enum SystemProxyObservationMode: Equatable {
    case stopped
    case enabled
    case cleanup
  }

  @Published var state: AgentRunState = .off
  @Published var systemProxyState: SystemProxyControlState = .idle
  /// 特权 helper 需要登录项批准（issue #71）：意图开启且 helper 不可用/待批准
  /// 时置位，呈现批准路径；helper 达到可用或意图关闭后复位。
  @Published var systemProxyApprovalRequired = false
  @Published var settings: ProxySettings
  /// 当前活动目标（菜单栏状态摘要与级联只读呈现用，issue #31）。machine 是
  /// 非发布值的普通结构体，代理关闭路径的激活动作不会触碰 state，菜单的
  /// 「目标」行依赖这里的独立发布保持实时。
  @Published var activeTargetID: NodeID?
  /// 最近一次激活预检在分组中跳过的服务器；仅记录 app 已知的本地阻塞原因。
  @Published var skippedServers: [SkippedServer] = []
  /// 最近一次激活拒绝或目标清除的点名原因。独立于运行状态呈现：agent 可
  /// 能仍在监听，激活失败不代表运行时停止（issue #60）。
  @Published var lastActivationFailure: ActivationFailure?
  var machine: ActivationStateMachine

  let catalogSnapshotReader: RuntimeCatalogSnapshotReading
  let activationFileStore: ActivationStateFileStore
  let runtimeFileStore: RuntimeFileStore
  let credentials: CredentialStoring
  let plugins: ManagedPluginProviding
  let settingsStore: ProxySettingsStoring
  /// 自定义规则持久化（issue #66）：规则模式 ACL 合并的用户入口。
  let customRuleStore: CustomRuleStore
  /// 监听设置不可读时的点名原因（D8「任何路径不静默改端口」）；非 nil 时
  /// 设置只是占位出厂默认，禁止部署（见 `deploy`）。
  var listenSettingsUnreadable: Bool
  /// 新版偏好不可读时同样禁止部署，不以出厂端口静默替代用户配置。
  var settingsUnreadable: Bool
  let agent: LaunchAgentControlling
  let probe: EndpointProbing
  let systemProxy: SystemProxyControlling
  let systemProxyHelper: SystemProxyHelperServicing
  let systemProxyNetworkChangeMonitor: SystemProxyNetworkChangeMonitoring
  let firewallChecker: FirewallStatusChecking
  let firewallExecutableURLs: [URL]
  let firewallPollIntervalNanoseconds: UInt64
  let launchHealthTimeoutSeconds: TimeInterval
  /// 信号发送缝（默认 kill），单测观测 SIGUSR1 投递。
  let sendSignal: @Sendable (Int32, Int32) -> Int32
  let processIsAlive: @Sendable (Int32) -> Bool
  /// 并发流代际：停止请求可使进行中的启动探测立即失效。
  var flowGeneration = 0
  var modeChangeGeneration = 0
  var lastDocument: SslocalRuntimeDocument?
  var firewallObservationTask: Task<Void, Never>?
  var systemProxyObservationMode = SystemProxyObservationMode.stopped
  var systemProxyCleanupRescanRequested = false
  var systemProxyCleanupTask: Task<SystemProxyControlState, Never>?
  var systemProxyConvergenceScheduled = false

  @Published var proxyMode: ProxyMode

  /// 规则模式子选项（issue #63）：从设置快照投影。
  var ruleDefaultAction: RuleDefaultAction { settings.ruleDefaultAction }

  init(
    catalogSnapshotReader: RuntimeCatalogSnapshotReading,
    activationFileStore: ActivationStateFileStore = ActivationStateFileStore(
      fileURL: ActivationStateFileStore.defaultFileURL()),
    runtimeFileStore: RuntimeFileStore = RuntimeFileStore(),
    credentials: CredentialStoring = KeychainCredentialStore(),
    plugins: ManagedPluginProviding = BundleManagedPluginProvider(),
    listenRestore: RestoredListenSettings = ListenSettingsFileStore.restored(),
    settingsStore: ProxySettingsStoring = ProxySettingsFileStore(),
    customRuleStore: CustomRuleStore = CustomRuleStore(),
    settingsRestore: RestoredProxySettings? = nil,
    agent: LaunchAgentControlling = SMAppLaunchAgentService(),
    probe: EndpointProbing = SystemEndpointProbe(),
    systemProxy: SystemProxyControlling = XPCSystemProxyController(),
    systemProxyHelper: SystemProxyHelperServicing = SMAppServiceSystemProxyHelper(),
    systemProxyNetworkChangeMonitor: SystemProxyNetworkChangeMonitoring =
      NoopSystemProxyNetworkChangeMonitor(),
    proxyMode: ProxyMode? = nil,
    firewallChecker: FirewallStatusChecking = SocketFilterFirewallChecker(),
    firewallExecutableURLs: [URL]? = nil,
    firewallPollIntervalNanoseconds: UInt64 = 2_000_000_000,
    launchHealthTimeoutSeconds: TimeInterval = 15,
    sendSignal: @escaping @Sendable (Int32, Int32) -> Int32 = { kill($0, $1) },
    processIsAlive: @escaping @Sendable (Int32) -> Bool = { $0 > 0 && kill($0, 0) == 0 }
  ) {
    self.catalogSnapshotReader = catalogSnapshotReader
    self.activationFileStore = activationFileStore
    self.runtimeFileStore = runtimeFileStore
    self.credentials = credentials
    self.plugins = plugins
    self.settingsStore = settingsStore
    self.customRuleStore = customRuleStore
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
    self.systemProxy = systemProxy
    self.systemProxyHelper = systemProxyHelper
    self.systemProxyNetworkChangeMonitor = systemProxyNetworkChangeMonitor
    self.firewallChecker = firewallChecker
    self.firewallExecutableURLs = firewallExecutableURLs ?? Self.defaultFirewallExecutableURLs
    self.firewallPollIntervalNanoseconds = firewallPollIntervalNanoseconds
    self.launchHealthTimeoutSeconds = launchHealthTimeoutSeconds
    self.sendSignal = sendSignal
    self.processIsAlive = processIsAlive
    let persistedTarget = try? activationFileStore.loadActiveTargetID()
    machine = ActivationStateMachine(activeTargetID: persistedTarget)
    activeTargetID = machine.activeTargetID
    self.proxyMode = proxyMode ?? Self.makeProxyMode(from: restoredSettings.settings)
  }
}
