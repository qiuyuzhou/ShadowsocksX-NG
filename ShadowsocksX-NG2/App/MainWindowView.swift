import SwiftUI

private enum WorkspaceSheet: String, Identifiable {
  case importURL
  case qrImport
  case legacyImport
  case addSubscription

  var id: String { rawValue }

  var destination: WorkspaceDestination {
    switch self {
    case .importURL, .qrImport, .legacyImport:
      .servers
    case .addSubscription:
      .subscriptions
    }
  }
}

/// 主窗口外壳（地图 #52，票 #53）：NavigationSplitView 侧栏承载五项导航与
/// 底部常驻代理状态卡；详情区按 route destination 承载各分区视图。分区名即
/// 窗口标题（navigationTitle 绑定 route destination，ADR 0016 的 scene 版
/// 窗口原生呈现）；订阅/诊断的页级动作经 .toolbar 桥接进窗口工具栏右端
/// （票 #56/#58 的槽位仅呈现位置变化），设置的表单级提交动作在其视图内容
/// 顶部（见 SettingsView）。路由状态仍由 WorkspaceRoute 持有；代理状态卡的
/// 状态与摘要只来自代理控制工作流的整体 snapshot（issue #47），与状态菜单
/// 使用同一口径。
struct MainWindowView: View {
  @ObservedObject var route: WorkspaceRoute
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  @ObservedObject var proxyController: ProxyRuntimeController
  @ObservedObject var diagnostics: DiagnosticsWorkflow
  @ObservedObject var settingsWorkflow: SettingsWorkflow
  @ObservedObject var loginController: LaunchAtLoginController
  @ObservedObject var silentLaunch: SilentLaunchController
  /// 目录树折叠状态：组合根持有的长寿命对象，跨 destination 切换存续；服务器
  /// 侧栏使用（见 CatalogExpansionState）；首页独立保存浏览状态。
  @ObservedObject var expansion: CatalogExpansionState
  let clipboard: any TextClipboard
  let diagnosticReportExporter: any DiagnosticReportExporter
  let configurationGroupFileExporter: any ConfigurationGroupFileExporter

  @StateObject private var homeServerList = HomeServerListState()
  @State private var selection: NodeID?
  /// 全局添加菜单打开的表单，以及诊断导出由窗口壳持有。
  @State private var presentedWorkspaceSheet: WorkspaceSheet?
  @State private var exportedDiagnosticsPath: String?
  @StateObject private var shellActionErrors = ErrorAlertPresenter()

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 210, ideal: 236, max: 300)
        .toolbar {
          ToolbarItem(placement: .automatic) {
            addMenu
          }
        }
    } detail: {
      destinationView
    }
    .onChange(of: workflow.tree, initial: true) {
      homeServerList.update(tree: workflow.tree, activeTargetID: control.snapshot.activeTarget?.id)
    }
    .navigationTitle(route.destination.label)
    .frame(minWidth: 920, minHeight: 580)
    .toolbar {
      ToolbarItemGroup(placement: .primaryAction) {
        destinationActions
      }
    }
    .sheet(item: $presentedWorkspaceSheet) { sheet in
      switch sheet {
      case .importURL:
        ImportURLSheet(
          workflow: workflow, errors: shellActionErrors, clipboard: clipboard,
          selection: $selection)
      case .qrImport:
        QRImportSheet(workflow: workflow, errors: shellActionErrors, selection: $selection)
      case .legacyImport:
        LegacyImportSheet(workflow: workflow)
      case .addSubscription:
        AddSubscriptionSheet(workflow: workflow, errors: shellActionErrors)
      }
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { shellActionErrors.isPresented },
        set: { if !$0 { shellActionErrors.dismiss() } })
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(shellActionErrors.message ?? "")
    }
    .alert(
      "诊断已导出",
      isPresented: Binding(
        get: { exportedDiagnosticsPath != nil },
        set: { if !$0 { exportedDiagnosticsPath = nil } })
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(exportedDiagnosticsPath ?? "")
    }
  }

  // MARK: - 分区动作槽位

  private var addMenu: some View {
    Menu {
      Button("通过 URL 导入…") { presentWorkspaceSheet(.importURL) }
      Button("从二维码图片导入…") { presentWorkspaceSheet(.qrImport) }
      if workflow.legacyImportState.snapshotFound {
        Button(legacyImportActionTitle) { presentWorkspaceSheet(.legacyImport) }
      }
      Divider()
      Button("添加订阅…") { presentWorkspaceSheet(.addSubscription) }
    } label: {
      Label("添加", systemImage: "plus")
    }
    .labelStyle(.iconOnly)
    .help("添加")
  }

  private var legacyImportActionTitle: String {
    workflow.legacyImportState.completed ? "再次导入旧版本服务器…" : "导入旧版本服务器…"
  }

  private func presentWorkspaceSheet(_ sheet: WorkspaceSheet) {
    route.navigate(to: sheet.destination)
    presentedWorkspaceSheet = sheet
  }

  /// 分区动作（票 #53/#56/#57）：页级动作随 destination 切换，经工具栏桥接
  /// 出现在窗口工具栏右端；首页/服务器无页级动作。例外：设置的保存/恢复
  /// 默认是表单级提交动作，由 SettingsView 内容顶部行承载（动作与表单同置，
  /// 工具栏呈现效果差）。sheet/alert 呈现状态仍由壳持有，本处只负责动作的
  /// 呈现。
  @ViewBuilder
  private var destinationActions: some View {
    switch route.destination {
    case .subscriptions:
      HStack(spacing: 8) {
        if !workflow.refreshingSubscriptionIDs.isEmpty {
          ProgressView()
            .controlSize(.small)
        }
        Button("更新全部", systemImage: "arrow.triangle.2.circlepath") {
          Task { await workflow.refreshAllSubscriptions() }
        }
        .disabled(workflow.subscriptions.isEmpty)
      }
    case .diagnostics:
      Button("导出诊断…", systemImage: "square.and.arrow.up") {
        exportDiagnostics()
      }
    case .home, .servers, .settings:
      EmptyView()
    }
  }

  /// 诊断导出（票 #58）：沿用 DiagnosticReportExportAction 既有入口；文件写
  /// 入成功后才登记导出完成事件。
  private func exportDiagnostics() {
    switch DiagnosticReportExportAction(
      diagnostics: diagnostics, exporter: diagnosticReportExporter
    ).perform()
    {
    case .preparationFailed(let failure):
      shellActionErrors.present(failure)
    case .cancelled:
      break
    case .saved(let url):
      diagnostics.noteExportCompleted()
      exportedDiagnosticsPath = url.path
    case .exportFailed(let failure):
      shellActionErrors.present(failure)
    }
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
        clipboard: clipboard,
        onManageServers: { route.navigate(to: .servers) })
    case .servers:
      ServersView(
        workflow: workflow,
        proxyController: proxyController,
        selection: $selection,
        expansion: expansion,
        clipboard: clipboard,
        configurationGroupFileExporter: configurationGroupFileExporter)
    case .subscriptions:
      WorkspaceSubscriptionsView(
        workflow: workflow,
        onNodesRemoved: clearSelectionIfInvalidated)
    case .settings:
      SettingsView(
        workflow: settingsWorkflow, loginController: loginController,
        silentLaunch: silentLaunch
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .diagnostics:
      WorkspaceDiagnosticsView(
        diagnostics: diagnostics,
        clipboard: clipboard)
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
    case .settings: "设置"
    case .diagnostics: "诊断"
    }
  }

  var systemImage: String {
    switch self {
    case .home: "house"
    case .servers: "server.rack"
    case .subscriptions: "arrow.triangle.2.circlepath"
    case .settings: "gearshape"
    case .diagnostics: "chart.bar"
    }
  }
}

// MARK: - 侧栏与底部代理状态卡（同文件扩展，保持 private 访问）

extension MainWindowView {
  // MARK: - 侧栏

  private var sidebar: some View {
    List(selection: navigationBinding) {
      Section {
        ForEach(WorkspaceDestination.allCases) { destination in
          sidebarRow(destination)
            .tag(destination)
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .top, spacing: 4) { identityHeader }
    .safeAreaInset(edge: .bottom, spacing: 4) { statusCard }
  }

  private var identityHeader: some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(Color.primary)
        Image(systemName: "network")
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

  private var navigationBinding: Binding<WorkspaceDestination?> {
    Binding(
      get: { route.destination },
      set: { destination in
        guard let destination else { return }
        route.navigate(to: destination)
      })
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
    func leaves(_ nodes: [CatalogTreeNode]) -> Int {
      nodes.reduce(0) { $0 + ($1.isGroup ? leaves($1.childNodes) : 1) }
    }
    return leaves(workflow.tree.roots)
  }

  // MARK: - 底部代理状态卡

  /// 底部状态卡（issue #60）：分别呈现 agent 运行状态、系统代理实际应用、
  /// 活动目标与模式；所有状态均来自同一 snapshot。
  private var statusCard: some View {
    let summary = StatusMenuModel.summary(from: control.snapshot)
    let targetDisplay = targetPresentation(for: summary)
    return VStack(alignment: .leading, spacing: 7) {
      statusRow("后台代理", value: summary.status, color: runtimeStatusColor)
      if let detail = summary.detail {
        statusDetail(detail, color: runtimeDetailColor)
      }
      statusRow(
        "系统代理设置", value: summary.systemProxyStateLabel, color: systemProxyStatusColor)
      if let systemProxyDetail = summary.systemProxyDetail {
        statusDetail(systemProxyDetail, color: .red)
      }

      Text(targetDisplay.text)
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        .truncationMode(.middle)
        .help(targetDisplay.help)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("活动目标：\(targetDisplay.text)")

      HStack(spacing: 0) {
        Text("模式：")
          .foregroundStyle(.secondary)
        Text(control.snapshot.proxyMode.label)
        if control.snapshot.proxyMode == .rule {
          Text("·")
          Text(control.snapshot.ruleDefaultAction.label)
        }
      }
      .font(.caption)
      .accessibilityElement(children: .combine)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.background.secondary, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    .overlay(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .strokeBorder(.quaternary)
    )
    .padding(.horizontal, 12)
    .padding(.top, 8)
    .padding(.bottom, 12)
  }

  private func statusRow(_ label: String, value: String, color: Color) -> some View {
    HStack(spacing: 4) {
      Text("\(label)：")
        .foregroundStyle(.secondary)
      Text(value)
        .fontWeight(.semibold)
        .foregroundStyle(color)
    }
    .font(.footnote)
    .lineLimit(1)
    .accessibilityElement(children: .combine)
  }

  private func statusDetail(_ detail: String, color: Color) -> some View {
    Text(detail)
      .font(.caption)
      .foregroundStyle(color)
      .lineLimit(2)
      .frame(maxWidth: .infinity, alignment: .leading)
      .help(detail)
  }

  private func targetPresentation(for summary: StatusMenuModel.Summary) -> (
    text: String, help: String
  ) {
    if let targetPath = summary.targetPath {
      return (targetPath, "活动目标：\(targetPath)")
    }
    if control.snapshot.proxyMode == .direct {
      return ("直连模式（无需服务器）", "直连模式无需选择活动目标")
    }
    return ("未激活", "未设置活动目标；在首页或服务器目录中激活")
  }

  private var runtimeStatusColor: Color {
    switch control.snapshot.runtime.status {
    case .running:
      .green
    case .starting:
      .secondary
    case .off:
      .secondary
    case .firewallBlocked, .requiresApproval:
      .orange
    case .launchFailed, .serviceFailed:
      .red
    }
  }

  private var runtimeDetailColor: Color {
    if control.snapshot.runtime.failure != nil {
      return runtimeStatusColor
    }
    return control.snapshot.activationFailure == nil ? .secondary : .red
  }

  private var systemProxyStatusColor: Color {
    switch control.snapshot.systemProxyApplication {
    case .idle:
      .secondary
    case .pending, .changed, .applying, .repairing, .paused:
      .orange
    case .applied:
      .green
    case .failed, .repairFailed, .clearFailed, .unreadable:
      .red
    }
  }

}
