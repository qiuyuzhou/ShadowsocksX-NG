import AppKit

/// 混合应用形态的 AppKit 生命周期家：LSUIElement 让进程默认纯后台
/// （accessory），主 workspace 可见期间由开窗 adapter 切成普通应用
/// （regular）；这里负责最后一个窗口关闭后切回纯后台。
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 混合形态的硬性要求：关窗不退进程，代理 GUI 仍驻留菜单栏。
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    NotificationCenter.default.addObserver(
      self, selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification, object: nil)
  }

  /// 前台形态下窗口被最小化时，Dock 点击只激活应用不会自动还原（SwiftUI
  /// 单 Window 场景不接管 reopen），这里补上标准语义；纯后台形态没有
  /// Dock 图标，不受影响。
  func applicationShouldHandleReopen(
    _ sender: NSApplication,
    hasVisibleWindows flag: Bool
  ) -> Bool {
    guard !flag else { return true }
    for window in sender.windows where window.isMiniaturized {
      window.deminiaturize(nil)
    }
    return true
  }

  /// 关最后一个可见主窗口 → 切回纯后台（与 WorkspaceWindowOpeningAdapter
  /// 的开窗切 .regular 构成同一形态契约的两半）。不用 occlusion state：
  /// Cmd+H 隐藏或窗口被完全遮挡也会失去 .visible，会把用户困在后台；
  /// willClose 只在真关窗时发出，隐藏不算关闭。
  @objc private func windowWillClose(_ notification: Notification) {
    let closingWindow = notification.object as? NSWindow
    // willClose 发出时窗口仍可见，推迟一轮 runloop 再清点剩余窗口。
    DispatchQueue.main.async {
      // 以「可成为主窗口」普查而不是比对 workspaceWindowID：SwiftUI 不保证
      // NSWindow 与 scene id 的稳定映射；本应用唯一的主窗口就是 workspace 窗口，
      // sheet/alert 均为 panel（canBecomeMain == false），不会误判。
      let hasWindow = NSApp.windows.contains {
        $0 !== closingWindow && $0.isVisible && $0.canBecomeMain
      }
      if !hasWindow {
        NSApp.setActivationPolicy(.accessory)
      }
    }
  }
}
