import Foundation

/// Legacy 交接视图模型（issue #37）：驱动「切换到 2.0」第二阶段——确认前置
/// （旧版 app 已退出）、执行白名单停用与系统代理清理，成功后启动 2.0 代理。
/// 端口门禁失败、bootout 失败都不启动 2.0（显式失败呈现，无静默回退）。
/// 与 ProxyRuntimeController 通过启停闭包解耦，便于测试。
@MainActor
final class LegacyHandoffViewModel: ObservableObject {
  enum Phase: Equatable {
    /// 尚未完成识别。
    case idle
    case ready
    case performing
    case completed
    case failed(String)
  }

  @Published private(set) var detection: LegacyHandoffDetection?
  @Published private(set) var phase: Phase = .idle
  @Published private(set) var report: LegacyHandoffReport?
  @Published private(set) var handoffCompleted: Bool
  /// 引导退出旧版 app 失败时的呈现面。
  @Published var presentedError: String?

  /// 交接成功后启动 2.0 代理（生产接线 ProxyRuntimeController.setProxyEnabled）；
  /// 执行前若 2.0 代理在跑则先停（重跑交接时 2.0 可能持有端口）。
  var startProxy: (() async -> Void)?
  var stopProxy: (() async -> Void)?

  private let service: LegacyHandoffService
  private let appController: LegacyAppControlling

  init(
    service: LegacyHandoffService = LegacyHandoffService(
      launchctl: ProcessLaunchctlController(),
      plistInspector: FileSystemLegacyAgentPlistInspector(),
      appController: WorkspaceLegacyAppController(),
      portsProvider: UserDefaultsLegacyListenPortsProvider(),
      occupancyProbe: SystemPortOccupancyProbe(),
      proxyCleaner: SystemConfigurationLegacyProxyCleaner(),
      marker: UserDefaultsLegacyHandoffMarkerStore()),
    appController: LegacyAppControlling = WorkspaceLegacyAppController()
  ) {
    self.service = service
    self.appController = appController
    handoffCompleted = service.isCompleted()
  }

  /// 只读识别（launchctl print 退出码 + plist 存在性 + 端口来源），不改任何
  /// launchd 状态、不动 Legacy 数据；process 派发避免阻塞主线程。
  func refresh() async {
    handoffCompleted = service.isCompleted()
    let detected = await Task.detached(priority: .userInitiated) {
      self.service.detect()
    }.value
    detection = detected
    if phase != .performing {
      phase = .ready
    }
  }

  /// 确认按钮的可用条件：识别完成、无未知状态、旧版 app 已退出、确有可停用
  /// 的痕迹（无可停用内容时不提供确认，避免无意义地走一遍流程）。
  var canConfirm: Bool {
    guard let detection, phase != .performing else { return false }
    guard detection.printFailures.isEmpty, !detection.legacyAppRunning else { return false }
    let plan = LegacyHandoffPlan.make(from: detection)
    return !plan.actions.isEmpty
  }

  var hasUnknownState: Bool {
    detection?.printFailures.isEmpty == false
  }

  /// 仍存在旧版运行痕迹（已加载 job、残留 plist 或旧版 app 本体）——主窗口
  /// 据此在交接完成后持续提供「Legacy 交接与残留」入口（D12「后续检测到残
  /// 留提示用户处理」）。
  var hasLegacyEvidence: Bool {
    guard let detection else { return false }
    return !detection.loadedLabels.isEmpty
      || detection.plists.contains { $0.fileExists }
      || detection.legacyAppRunning
  }

  func performHandoff() async {
    guard canConfirm else { return }
    phase = .performing
    await stopProxy?()
    do {
      let handoffReport = try await service.performHandoff()
      report = handoffReport
      handoffCompleted = true
      phase = .completed
      // 端口门禁通过后才启动 2.0（service 内部已确认）；启动失败在代理控制
      // 器状态与菜单栏点名呈现，不影响交接完成态。
      await startProxy?()
    } catch let error as LegacyHandoffError {
      phase = .failed(error.presentedReason)
    } catch {
      phase = .failed(String(describing: error))
    }
  }

  /// 引导退出旧版 app（优雅退出，等价用户点退出菜单）；退出后自动重新识别。
  func quitLegacyApp() {
    guard appController.requestGracefulQuit() else {
      presentedError = "无法向旧版 ShadowsocksX-NG 发送退出请求，请手动退出后重试"
      return
    }
    Task { await refresh() }
  }
}
