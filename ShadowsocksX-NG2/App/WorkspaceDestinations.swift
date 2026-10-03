import SwiftUI

/// 首页 destination 的包装视图：承载旧版导入主动弹窗与共享错误弹窗挂载
/// （票 #53/#54），行为委托给 HomeView。订阅/诊断分区自持错误弹窗（与
/// ServersView 同法），不再需要包装。

struct WorkspaceHomeView: View {
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  let serverList: HomeServerListState
  let clipboard: any TextClipboard
  let onManageServers: () -> Void
  @StateObject private var errors = ErrorAlertPresenter()

  @State private var showLegacyImportSheet = false
  @State private var didOfferLegacyImport = false

  var body: some View {
    HomeView(
      workflow: workflow,
      control: control,
      serverList: serverList,
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
    .presentingErrors(errors)
  }
}
