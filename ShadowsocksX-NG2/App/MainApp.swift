import SwiftUI

@main
struct ShadowsocksXNG2App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var proxyController: ProxyRuntimeController
  @StateObject private var catalogViewModel = CatalogViewModel()
  @StateObject private var loginController: LaunchAtLoginController

  init() {
    let settingsStore = ProxySettingsFileStore()
    let restoredSettings = ProxySettingsFileStore.restored(store: settingsStore)
    _proxyController = StateObject(
      wrappedValue: ProxyRuntimeController(
        listenRestore: RestoredListenSettings(
          settings: restoredSettings.settings.listen, unreadableError: nil),
        settingsStore: settingsStore,
        settingsRestore: restoredSettings))
    let loginController = LaunchAtLoginController()
    _loginController = StateObject(wrappedValue: loginController)
    Task { @MainActor in
      loginController.syncAtLaunch()
    }
    // GUI 事件接入内存环形缓冲（spec #21 D5，issue #34）：主窗口日志查看器与
    // 诊断导出的来源；wrapper 侧不注册，仍走 stderr → agent.log 收敛。
    RuntimeLog.setSink(RuntimeEventStore.shared)
  }

  var body: some Scene {
    MenuBarExtra("ShadowsocksX-NG 2.0", systemImage: "network") {
      ProxyStatusMenu(controller: proxyController, catalogViewModel: catalogViewModel)
        .task {
          // postCommit 在应用启动即接线（不只主窗口打开时）：菜单栏「立即更新
          // 全部订阅」（issue #35）等未开窗路径的目录提交同样立即重展开运行时。
          let controller = proxyController
          catalogViewModel.postCommit = { await controller.catalogDidCommit() }
          let loginController = loginController
          catalogViewModel.postLegacyImport = { outcome in
            await controller.legacyImportDidCommit()
            loginController.applyImportedValue(outcome.loginAtLogin)
          }
          // 全局快捷键（issue #31）：开关代理、切换模式，与菜单项同一入口。
          GlobalShortcuts.wire(controller: controller)
          await proxyController.resyncOnLaunch()
        }
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
        let loginController = loginController
        catalogViewModel.postLegacyImport = { outcome in
          await controller.legacyImportDidCommit()
          loginController.applyImportedValue(outcome.loginAtLogin)
        }
      }
    }
    .defaultLaunchBehavior(
      catalogViewModel.shouldOfferLegacyImport ? .automatic : .suppressed)

    Settings {
      SettingsView(
        proxyController: proxyController,
        loginController: loginController
      )
      .frame(width: 640, height: 760)
    }
  }
}
