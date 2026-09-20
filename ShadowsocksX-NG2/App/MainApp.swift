import SwiftUI

@main
struct ShadowsocksXNG2App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var proxyController = ProxyRuntimeController()
  @StateObject private var catalogViewModel = CatalogViewModel()

  init() {
    // GUI 事件接入内存环形缓冲（spec #21 D5，issue #34）：主窗口日志查看器与
    // 诊断导出的来源；wrapper 侧不注册，仍走 stderr → agent.log 收敛。
    RuntimeLog.setSink(RuntimeEventStore.shared)
  }

  var body: some Scene {
    MenuBarExtra("ShadowsocksX-NG 2.0", systemImage: "network") {
      ProxyStatusMenu(controller: proxyController)
        .task { await proxyController.resyncOnLaunch() }
    }
    .menuBarExtraStyle(.menu)

    Window("ShadowsocksX-NG 2.0", id: "main") {
      MainWindowView(
        viewModel: catalogViewModel, proxyController: proxyController,
        eventStore: .shared
      )
      .task {
        // 目录提交 → 代理运行时立即重展开（spec #21 D3「已提交编辑立即跟随」）。
        let controller = proxyController
        catalogViewModel.postCommit = { await controller.catalogDidCommit() }
      }
    }
    .defaultLaunchBehavior(.suppressed)
  }
}
