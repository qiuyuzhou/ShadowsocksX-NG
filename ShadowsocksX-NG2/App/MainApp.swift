import SwiftUI

@main
struct ShadowsocksXNG2App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var proxyController = ProxyRuntimeController()
  @StateObject private var catalogViewModel = CatalogViewModel()

  var body: some Scene {
    MenuBarExtra("ShadowsocksX-NG 2.0", systemImage: "network") {
      ProxyStatusMenu(controller: proxyController)
        .task { await proxyController.resyncOnLaunch() }
    }
    .menuBarExtraStyle(.menu)

    Window("ShadowsocksX-NG 2.0", id: "main") {
      MainWindowView(viewModel: catalogViewModel, proxyController: proxyController)
        .task {
          // 目录提交 → 代理运行时立即重展开（spec #21 D3「已提交编辑立即跟随」）。
          let controller = proxyController
          catalogViewModel.postCommit = { await controller.catalogDidCommit() }
        }
    }
    .defaultLaunchBehavior(.suppressed)
  }
}
