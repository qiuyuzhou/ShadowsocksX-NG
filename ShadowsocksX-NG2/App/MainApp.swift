import SwiftUI

@main
struct ShadowsocksXNG2App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var proxyController: ProxyRuntimeController
  @StateObject private var catalogWorkflow: CatalogWorkflow
  @StateObject private var loginController: LaunchAtLoginController

  init() {
    let settingsStore = ProxySettingsFileStore()
    let restoredSettings = ProxySettingsFileStore.restored(store: settingsStore)
    let controller = ProxyRuntimeController(
      listenRestore: RestoredListenSettings(
        settings: restoredSettings.settings.listen, unreadableError: nil),
      settingsStore: settingsStore,
      settingsRestore: restoredSettings)
    _proxyController = StateObject(wrappedValue: controller)
    let loginController = LaunchAtLoginController()
    _loginController = StateObject(wrappedValue: loginController)
    // 组合根（issue #40/#41）：目录提交协调器与生产运行时适配器只在此接线一次，
    // 各 scene 不再重复设置提交回调；Legacy 导入后的 2.0 运行时边界同为一次性注入。
    let coordinator = CatalogCommitCoordinator(
      fileStore: CatalogFileStore(fileURL: CatalogFileStore.defaultFileURL()),
      runtime: ProxyRuntimeSyncAdapter(controller: controller))
    _catalogWorkflow = StateObject(
      wrappedValue: CatalogWorkflow(
        coordinator: coordinator,
        postLegacyImport: { _ in
          await controller.legacyImportDidCommit()
        }))
    Task { @MainActor in
      loginController.syncAtLaunch()
    }
    // GUI 事件接入内存环形缓冲（spec #21 D5，issue #34）：主窗口日志查看器与
    // 诊断导出的来源；wrapper 侧不注册，仍走 stderr → agent.log 收敛。
    RuntimeLog.setSink(RuntimeEventStore.shared)
  }

  var body: some Scene {
    MenuBarExtra("ShadowsocksX-NG 2.0", systemImage: "network") {
      ProxyStatusMenu(controller: proxyController, catalogWorkflow: catalogWorkflow)
        .task {
          // 全局快捷键（issue #31）：开关代理、切换模式，与菜单项同一入口。
          GlobalShortcuts.wire(controller: proxyController)
          await proxyController.resyncOnLaunch()
        }
    }
    .menuBarExtraStyle(.menu)

    Window("ShadowsocksX-NG 2.0", id: "main") {
      MainWindowView(
        workflow: catalogWorkflow, proxyController: proxyController,
        eventStore: .shared
      )
    }
    .defaultLaunchBehavior(
      catalogWorkflow.legacyImportState.shouldOffer ? .automatic : .suppressed)

    // 菜单栏 app 没有可依赖的常规应用菜单；设置窗口必须有显式 scene ID，
    // 由状态菜单通过 openWindow(id:) 打开。
    Window("设置", id: "settings") {
      SettingsView(
        proxyController: proxyController,
        loginController: loginController
      )
      .frame(width: 640, height: 760)
    }
    .defaultLaunchBehavior(.suppressed)
  }
}
