import Combine

/// 单一主 workspace 的有限 destination 词汇。它只描述导航位置，不携带功能区
/// 的选择、sheet、alert 或编辑草稿。
enum WorkspaceDestination: String, CaseIterable, Hashable, Identifiable, Sendable {
  case home
  case servers
  case subscriptions
  case settings
  case diagnostics

  var id: Self { self }
}

/// workspace 的跨入口意图。呈现意图会要求主 workspace 可见；workspace 内部
/// 导航只改变 destination，不重复执行窗口 effect。
enum WorkspaceRouteIntent: Equatable, Sendable {
  case launch
  case navigate(destination: WorkspaceDestination)
  case present(destination: WorkspaceDestination)
  case reopen
}

/// 窄的开窗 seam。实现可以连接 SwiftUI `openWindow` 或 AppKit 生命周期，route
/// module 本身不依赖任一 UI framework。
@MainActor
protocol WorkspaceWindowOpening {
  func ensureWorkspaceVisible()
}

/// workspace route module：集中 destination、启动 policy、恢复 policy 与跨入口
/// intent 协调。路由状态只存在于进程内，新实例始终从 home 开始。
@MainActor
final class WorkspaceRoute: ObservableObject {
  @Published private(set) var destination: WorkspaceDestination = .home

  private var didApplyLaunchPolicy = false

  /// workspace 内部导航只改变 route destination，不请求新的窗口呈现。
  func navigate(to destination: WorkspaceDestination) {
    self.destination = destination
  }

  /// 应用一个 route intent，并在需要时请求主 workspace 可见。
  /// destination 总是在开窗 effect 之前更新，避免窗口先呈现旧位置再纠正。
  func handle(
    _ intent: WorkspaceRouteIntent,
    using windowOpening: any WorkspaceWindowOpening
  ) {
    switch intent {
    case .launch:
      // 启动策略（CONTEXT.md「Background form」不变量）：每次启动都呈现
      // 主 workspace（前台形态开窗）；Legacy 导入提示由已开窗口的 home 分区呈现。
      guard !didApplyLaunchPolicy else { return }
      didApplyLaunchPolicy = true
      windowOpening.ensureWorkspaceVisible()
    case .navigate(let destination):
      navigate(to: destination)
    case .present(let destination):
      self.destination = destination
      windowOpening.ensureWorkspaceVisible()
    case .reopen:
      windowOpening.ensureWorkspaceVisible()
    }
  }
}
