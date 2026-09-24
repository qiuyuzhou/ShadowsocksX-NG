import SwiftUI

/// 主窗口外壳（地图 #52，票 #53）：NavigationSplitView 侧栏承载五项导航与
/// 底部常驻代理状态卡；详情区按 route destination 承载既有五个分区视图，
/// 顶部是系统设置风格的分区大标题（动作槽位留给各分区票填充）。路由状态
/// 仍由 WorkspaceRoute 持有；代理状态卡的开关、模式与摘要只来自代理控制
/// 工作流的整体 snapshot（issue #47），与状态菜单同一口径。
struct MainWindowView: View {
  @ObservedObject var route: WorkspaceRoute
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  @ObservedObject var proxyController: ProxyRuntimeController
  @ObservedObject var diagnostics: DiagnosticsWorkflow
  @ObservedObject var settingsWorkflow: SettingsWorkflow
  @ObservedObject var loginController: LaunchAtLoginController
  let clipboard: any TextClipboard
  let diagnosticReportExporter: any DiagnosticReportExporter

  @State private var selection: NodeID?

  var body: some View {
    NavigationSplitView {
      sidebar
        .navigationSplitViewColumnWidth(min: 200, ideal: 236, max: 300)
    } detail: {
      VStack(spacing: 0) {
        destinationHeader(route.destination.label) {
          headerActions
        }
        destinationView
      }
    }
    .frame(minWidth: 920, minHeight: 580)
  }

  // MARK: - 分区标题与动作槽位

  @ViewBuilder
  private func destinationHeader<ActionContent: View>(
    _ title: String,
    @ViewBuilder actions: () -> ActionContent
  ) -> some View {
    VStack(spacing: 0) {
      HStack(alignment: .center) {
        Text(title)
          .font(.system(size: 28, weight: .bold))
          .lineLimit(1)
        Spacer(minLength: 16)
        actions()
      }
      .padding(.leading, 28)
      .padding(.trailing, 32)
      .padding(.top, 18)
      .padding(.bottom, 14)
      Divider()
    }
  }

  /// 分区头动作槽位：各分区票落地时把页级动作（添加、保存、导出等）迁入。
  @ViewBuilder
  private var headerActions: some View {
    switch route.destination {
    case .home, .servers, .subscriptions, .settings, .diagnostics:
      EmptyView()
    }
  }

  // MARK: - 分区承载

  @ViewBuilder
  private var destinationView: some View {
    switch route.destination {
    case .home:
      WorkspaceHomeView(workflow: workflow)
    case .servers:
      ServersView(
        workflow: workflow,
        proxyController: proxyController,
        selection: $selection,
        clipboard: clipboard)
    case .subscriptions:
      WorkspaceSubscriptionsView(
        workflow: workflow,
        onNodesRemoved: clearSelectionIfInvalidated)
    case .settings:
      SettingsView(workflow: settingsWorkflow, loginController: loginController)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .diagnostics:
      WorkspaceDiagnosticsView(
        diagnostics: diagnostics,
        clipboard: clipboard,
        reportExporter: diagnosticReportExporter)
    }
  }

  private func clearSelectionIfInvalidated(_ removed: Set<NodeID>) {
    if let selection, removed.contains(selection) {
      self.selection = nil
    }
  }
}

// MARK: - 分区包装（票 #53）

private struct WorkspaceHomeView: View {
  @ObservedObject var workflow: CatalogWorkflow

  @State private var showLegacyImportSheet = false
  @State private var didOfferLegacyImport = false

  var body: some View {
    ContentUnavailableView(
      "首页", systemImage: "house",
      description: Text("从侧栏选择服务器、订阅、设置或诊断。")
    )
    .sheet(isPresented: $showLegacyImportSheet) {
      LegacyImportSheet(workflow: workflow)
    }
    .onAppear {
      guard !didOfferLegacyImport, workflow.legacyImportState.shouldOffer else { return }
      didOfferLegacyImport = true
      showLegacyImportSheet = true
    }
  }
}

private struct WorkspaceSubscriptionsView: View {
  @ObservedObject var workflow: CatalogWorkflow
  let onNodesRemoved: (Set<NodeID>) -> Void
  @StateObject private var errors = ErrorAlertPresenter()

  var body: some View {
    SubscriptionsView(
      workflow: workflow,
      errors: errors,
      onNodesRemoved: onNodesRemoved
    )
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { errors.isPresented },
        set: { if !$0 { errors.dismiss() } })
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(errors.message ?? "")
    }
  }
}

private struct WorkspaceDiagnosticsView: View {
  @ObservedObject var diagnostics: DiagnosticsWorkflow
  let clipboard: any TextClipboard
  let reportExporter: any DiagnosticReportExporter
  @StateObject private var errors = ErrorAlertPresenter()

  var body: some View {
    HStack(spacing: 0) {
      DiagnosticsSummarySidebar(workflow: diagnostics)
        .frame(width: 220)
      Divider()
      DiagnosticsView(
        diagnostics: diagnostics,
        errors: errors,
        clipboard: clipboard,
        reportExporter: reportExporter
      )
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .alert(
        "操作失败",
        isPresented: Binding(
          get: { errors.isPresented },
          set: { if !$0 { errors.dismiss() } })
      ) {
        Button("好", role: .cancel) {}
      } message: {
        Text(errors.message ?? "")
      }
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
    .safeAreaInset(edge: .top, spacing: 0) { identityHeader }
    .safeAreaInset(edge: .bottom, spacing: 0) { statusCard }
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
      Text("ShadowsocksX-NG")
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

  private var statusCard: some View {
    let summary = StatusMenuModel.summary(from: control.snapshot)
    return VStack(alignment: .leading, spacing: 7) {
      HStack(spacing: 8) {
        Toggle("代理开关", isOn: proxyToggleBinding)
          .toggleStyle(.switch)
          .controlSize(.mini)
          .labelsHidden()
        Text(summary.status)
          .font(.footnote.weight(.semibold))
          .foregroundStyle(statusColor(summary))
          .lineLimit(1)
      }
      Text(summary.targetPath ?? "未激活")
        .font(.footnote.weight(.medium))
        .lineLimit(1)
        .truncationMode(.middle)
        .help(
          summary.targetPath.map { "活动目标：\($0)" }
            ?? "未设置活动目标；在首页或服务器目录中激活")
      Text("模式：\(summary.modeLabel)")
        .font(.caption)
        .foregroundStyle(.secondary)
      if let detail = summary.detail {
        Text(detail)
          .font(.caption)
          .foregroundStyle(.orange)
          .lineLimit(2)
          .help(detail)
      }
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

  private var proxyToggleBinding: Binding<Bool> {
    Binding(
      get: { control.snapshot.runtime.isOn },
      set: { enabled in
        Task { await control.setProxyEnabled(enabled) }
      })
  }

  private func statusColor(_ summary: StatusMenuModel.Summary) -> Color {
    switch control.snapshot.runtime.status {
    case .running:
      .green
    case .starting:
      .secondary
    case .off:
      .secondary
    case .firewallBlocked, .requiresApproval:
      .orange
    case .launchFailed, .activationFailed, .serviceFailed, .systemProxyFailed:
      .red
    }
  }

}
