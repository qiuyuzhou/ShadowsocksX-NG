import SwiftUI

@main
struct ShadowsocksXNG2App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var proxyController = ProxyRuntimeController()

  var body: some Scene {
    MenuBarExtra("ShadowsocksX-NG 2.0", systemImage: "network") {
      ProxyStatusMenu(controller: proxyController)
        .task { await proxyController.resyncOnLaunch() }
    }
    .menuBarExtraStyle(.menu)

    Window("ShadowsocksX-NG 2.0", id: "main") {
      PlaceholderMainWindow()
    }
    .defaultLaunchBehavior(.suppressed)
  }
}
