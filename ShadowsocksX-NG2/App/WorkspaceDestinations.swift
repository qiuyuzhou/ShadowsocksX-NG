import SwiftUI

/// 主窗口各 destination 的包装视图（票 #53/#54）：负责每个分区的共享
/// alert/sheet 生命周期，行为委托给既有分区视图。

struct WorkspaceHomeView: View {
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  let clipboard: any TextClipboard
  let onManageServers: () -> Void
  @StateObject private var errors = ErrorAlertPresenter()

  @State private var showLegacyImportSheet = false
  @State private var didOfferLegacyImport = false

  var body: some View {
    HomeView(
      workflow: workflow,
      control: control,
      clipboard: clipboard,
      onManageServers: onManageServers,
      errors: errors
    )
    .sheet(isPresented: $showLegacyImportSheet) {
      LegacyImportSheet(workflow: workflow)
    }
    .onAppear {
      guard !didOfferLegacyImport, workflow.legacyImportState.shouldOffer else { return }
      didOfferLegacyImport = true
      showLegacyImportSheet = true
    }
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

struct WorkspaceSubscriptionsView: View {
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

struct WorkspaceDiagnosticsView: View {
  @ObservedObject var diagnostics: DiagnosticsWorkflow
  let clipboard: any TextClipboard
  @StateObject private var errors = ErrorAlertPresenter()

  var body: some View {
    // 导出诊断动作在窗口工具栏（票 #58）；本包装只承载复制错误呈现。
    DiagnosticsView(
      diagnostics: diagnostics,
      errors: errors,
      clipboard: clipboard
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
