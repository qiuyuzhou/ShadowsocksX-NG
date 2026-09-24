import SwiftUI

/// 单主 workspace host。它只把 route destination 映射到已有 feature view；目录、
/// 订阅、设置与诊断的行为仍由各自既有 module/view 持有。
struct MainWindowView: View {
  @ObservedObject var route: WorkspaceRoute
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var proxyController: ProxyRuntimeController
  @ObservedObject var diagnostics: DiagnosticsWorkflow
  @ObservedObject var settingsWorkflow: SettingsWorkflow
  @ObservedObject var loginController: LaunchAtLoginController
  let clipboard: any TextClipboard
  let diagnosticReportExporter: any DiagnosticReportExporter

  @State private var selection: NodeID?

  var body: some View {
    VStack(spacing: 0) {
      WorkspaceDestinationPicker(route: route)
      destinationView
    }
    .frame(minWidth: 720, minHeight: 420)
  }

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

private struct WorkspaceDestinationPicker: View {
  @ObservedObject var route: WorkspaceRoute

  var body: some View {
    Picker("工作区", selection: destinationBinding) {
      ForEach(WorkspaceDestination.allCases) { destination in
        Text(destination.label).tag(destination)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
  }

  private var destinationBinding: Binding<WorkspaceDestination> {
    Binding(
      get: { route.destination },
      set: { route.navigate(to: $0) })
  }
}

private struct WorkspaceHomeView: View {
  @ObservedObject var workflow: CatalogWorkflow

  @State private var showLegacyImportSheet = false
  @State private var didOfferLegacyImport = false

  var body: some View {
    ContentUnavailableView(
      "首页", systemImage: "house",
      description: Text("从工作区导航选择服务器、订阅、设置或诊断。")
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
    NavigationSplitView {
      DiagnosticsSummarySidebar(workflow: diagnostics)
    } detail: {
      DiagnosticsView(
        diagnostics: diagnostics,
        errors: errors,
        clipboard: clipboard,
        reportExporter: reportExporter
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
}

extension WorkspaceDestination {
  fileprivate var label: String {
    switch self {
    case .home: "首页"
    case .servers: "服务器"
    case .subscriptions: "订阅"
    case .settings: "设置"
    case .diagnostics: "诊断"
    }
  }
}
