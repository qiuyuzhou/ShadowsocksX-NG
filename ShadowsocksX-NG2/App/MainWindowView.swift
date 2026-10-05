import SwiftUI

/// 服务器导入面板：由边栏工具栏「导入服务器配置」按钮打开，窗口壳统一持有
/// 呈现；添加订阅表单由订阅分区自持（SubscriptionsView）。
private enum WorkspaceSheet: String, Identifiable {
  case importServers

  var id: String { rawValue }
}

/// 主窗口外壳（地图 #52，票 #53）：NavigationSplitView 侧栏承载五项导航与
/// 底部常驻代理状态卡；详情区按 route destination 承载各分区视图。分区名即
/// 窗口标题（navigationTitle 绑定 route destination，ADR 0016 的 scene 版
/// 窗口原生呈现）；页级动作由各分区视图自挂 toolbar（呈现于窗口工具栏右
/// 端，与服务器分区同法，票 #56/#58 的槽位仅呈现位置），设置的表单级提交
/// 动作在其视图内容顶部（见 SettingsView）。路由状态仍由 WorkspaceRoute
/// 持有；代理状态卡的
/// 状态、摘要与配色政策全部经 StatusCardModel 从代理控制工作流的整体
/// snapshot 派生（issue #47，与状态菜单同口径），本壳只挂 StatusCardView；
/// 服务器分区的活动目标标记同源（snapshot.activeTarget）。
struct MainWindowView: View {
  /// 纯转发的分区工作流与控制器：壳 body 不读它们（分区视图自行观察），
  /// 用 let 转发，壳不重复订阅它们的发布。
  let rulesWorkflow: RulesWorkflow
  @ObservedObject var route: WorkspaceRoute
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  let diagnostics: DiagnosticsWorkflow
  let plugins: PluginManagementModel
  let settingsWorkflow: SettingsWorkflow
  let loginController: LaunchAtLoginController
  let silentLaunch: SilentLaunchController
  /// 目录树折叠状态：组合根持有的长寿命对象，跨 destination 切换存续；服务器
  /// 侧栏使用（见 CatalogExpansionState）；首页独立保存浏览状态。
  let expansion: CatalogExpansionState
  let clipboard: any TextClipboard
  let diagnosticReportExporter: any DiagnosticReportExporter
  let configurationGroupFileExporter: any ConfigurationGroupFileExporter

  @StateObject private var homeServerList = HomeServerListState()
  /// 激活反馈共享状态：首页目标树、侧栏右键与分组详情三个激活入口共用。
  @StateObject private var activationFeedback = ActivationFeedbackState()
  /// 侧栏选中项中转：macOS 的 List/NavigationSplitView 会在视图更新期间回写
  /// selection（选择再同步，且可能携带缓存的旧值），回写必须落在 SwiftUI 自管
  /// 的 @State 上，再经 onChange 单向驱动 route；直接 publish 到 route 会触发
  /// view-update 期间发布警告，且缓存的旧值会把外部导航弹回。route 的外部
  /// 导航（导入菜单、规则编辑器返回等）经 sidebar 上的 onChange 回填选中项。
  /// 初值须与 WorkspaceRoute 的初始 destination 对齐，否则首帧侧栏无高亮行。
  @State private var sidebarSelection: WorkspaceDestination? = WorkspaceRoute.initialDestination
  @State private var selection: NodeID?
  /// 全局导入面板由窗口壳持有。
  @State private var presentedWorkspaceSheet: WorkspaceSheet?

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 236, ideal: 250, max: 300)
        .toolbar {
          ToolbarItem(placement: .automatic) {
            importButton
          }
        }
    } detail: {
      destinationView
        .toolbar {
          // macOS 会在详情工具栏项从零变为非零（或反向）时淡入淡出整条
          // 工具栏背景，连带常驻边栏按钮闪烁。保留不可见的零尺寸项，
          // 让各页面始终有详情工具栏内容；EmptyView / Spacer 会被系统省略。
          ToolbarItem(id: "workspace-detail-toolbar-anchor", placement: .primaryAction) {
            Color.clear
              .frame(width: 0, height: 0)
              .hidden()
              .allowsHitTesting(false)
              .accessibilityHidden(true)
          }
        }
    }
    .onChange(of: workflow.tree, initial: true) {
      homeServerList.update(tree: workflow.tree, activeTargetID: control.snapshot.activeTarget?.id)
    }
    .navigationTitle(route.destination.label)
    .frame(minWidth: 920, minHeight: 580)
    .sheet(item: $presentedWorkspaceSheet) { sheet in
      switch sheet {
      case .importServers:
        ImportServersSheet(
          workflow: workflow, clipboard: clipboard, selection: $selection)
      }
    }
  }

  // MARK: - 全局导入入口

  private var importButton: some View {
    Button {
      presentWorkspaceSheet(.importServers)
    } label: {
      Label("导入", systemImage: "square.and.arrow.down")
    }
    .help("导入")
  }

  private func presentWorkspaceSheet(_ sheet: WorkspaceSheet) {
    route.navigate(to: .servers)
    presentedWorkspaceSheet = sheet
  }

  // MARK: - 分区承载

  @ViewBuilder
  private var destinationView: some View {
    switch route.destination {
    case .home:
      WorkspaceHomeView(
        workflow: workflow,
        control: control,
        serverList: homeServerList,
        activation: activationFeedback,
        clipboard: clipboard,
        onManageServers: { route.navigate(to: .servers) })
    case .servers:
      ServersView(
        workflow: workflow,
        activation: activationFeedback,
        activeTargetID: control.snapshot.activeTarget?.id,
        selection: $selection,
        expansion: expansion,
        clipboard: clipboard,
        configurationGroupFileExporter: configurationGroupFileExporter)
    case .subscriptions:
      SubscriptionsView(
        workflow: workflow,
        onNodesRemoved: clearSelectionIfInvalidated)
    case .rules:
      RulesView(workflow: rulesWorkflow)
    case .settings:
      SettingsView(
        plugins: plugins, workflow: settingsWorkflow, loginController: loginController,
        silentLaunch: silentLaunch
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .diagnostics:
      DiagnosticsView(
        diagnostics: diagnostics,
        clipboard: clipboard,
        exporter: diagnosticReportExporter)
    }
  }

  private func clearSelectionIfInvalidated(_ removed: Set<NodeID>) {
    if let selection, removed.contains(selection) {
      self.selection = nil
    }
  }
}

extension WorkspaceDestination {
  var label: String {
    switch self {
    case .home: "首页"
    case .servers: "服务器"
    case .subscriptions: "订阅"
    case .rules: RulesCopy.text("代理规则")
    case .settings: "设置"
    case .diagnostics: "诊断"
    }
  }

  var systemImage: String {
    switch self {
    case .home: "house"
    case .servers: "server.rack"
    case .subscriptions: "arrow.triangle.2.circlepath"
    case .rules: "list.bullet.rectangle"
    case .settings: "gearshape"
    case .diagnostics: "chart.bar"
    }
  }
}

// MARK: - 侧栏（同文件扩展，保持 private 访问）

extension MainWindowView {
  // MARK: - 侧栏

  private var sidebar: some View {
    List(selection: $sidebarSelection) {
      Section {
        ForEach(WorkspaceDestination.allCases) { destination in
          sidebarRow(destination)
            .tag(destination)
        }
      }
    }
    .listStyle(.sidebar)
    // 点击行 → @State 选中项 → route；nil 回写无对应 destination，忽略。
    .onChange(of: sidebarSelection) { _, destination in
      guard let destination else { return }
      route.navigate(to: destination)
    }
    // route 的外部导航 → 回填选中项；等值不写，避免导航回声。
    .onChange(of: route.destination) { _, destination in
      if sidebarSelection != destination {
        sidebarSelection = destination
      }
    }
    .safeAreaInset(edge: .top, spacing: 4) { identityHeader }
    .safeAreaInset(edge: .bottom, spacing: 4) { StatusCardView(control: control) }
  }

  private var identityHeader: some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.primary)
        Image(systemName: "paperplane.fill")
          .font(.system(size: 15, weight: .semibold))
          .foregroundStyle(Color(nsColor: .windowBackgroundColor))
      }
      .frame(width: 30, height: 30)
      Text("ShadowsocksX-NG2")
        .font(.headline)
      Spacer(minLength: 0)
    }
    .padding(.leading, 16)
    .padding(.trailing, 12)
    .padding(.top, 12)
    .padding(.bottom, 4)
  }

  private func sidebarRow(_ destination: WorkspaceDestination) -> some View {
    HStack(spacing: 8) {
      Label(destination.label, systemImage: destination.systemImage)
      Spacer(minLength: 0)
      if let count = badgeCount(for: destination) {
        Text("\(count)")
          .font(.caption2.monospacedDigit())
          .foregroundStyle(.secondary)
          .padding(.horizontal, 6)
          .padding(.vertical, 1)
          .background(Capsule().fill(.quaternary))
      }
    }
  }

  /// 行尾数量角标：服务器 = 目录树内服务器叶子数；订阅 = 订阅数。
  private func badgeCount(for destination: WorkspaceDestination) -> Int? {
    switch destination {
    case .servers:
      serverLeafCount > 0 ? serverLeafCount : nil
    case .subscriptions:
      workflow.subscriptions.isEmpty ? nil : workflow.subscriptions.count
    default:
      nil
    }
  }

  private var serverLeafCount: Int {
    workflow.tree.serverLeafCount
  }

}

// MARK: - 首页 destination 包装壳

/// 首页 destination 的包装视图：承载共享错误弹窗挂载（票 #53/#54），行为
/// 委托给 HomeView。旧版导入的主动弹窗已移除（docs/design/unified-server-
/// import.md），发现状态仅供统一导入面板的 Legacy 入口显隐。
private struct WorkspaceHomeView: View {
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  let serverList: HomeServerListState
  let activation: ActivationFeedbackState
  let clipboard: any TextClipboard
  let onManageServers: () -> Void
  @StateObject private var errors = ErrorAlertPresenter()

  var body: some View {
    HomeView(
      workflow: workflow,
      control: control,
      serverList: serverList,
      activation: activation,
      clipboard: clipboard,
      onManageServers: onManageServers,
      errors: errors
    )
    .presentingErrors(errors)
  }
}
