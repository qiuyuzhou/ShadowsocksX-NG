import AppKit

/// 混合应用形态的 AppKit 生命周期家：LSUIElement 让进程默认纯后台
/// （accessory），这里负责前台形态的进入与退出——任意路径使主窗口可见
/// 时切成普通应用（regular），最后一个窗口关闭后切回纯后台。
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// 混合形态的硬性要求：关窗不退进程，代理 GUI 仍驻留菜单栏。
  func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
    false
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    // 启动即进入前台形态（CONTEXT.md「每次启动呈现主窗口」不变量）：LSUIElement
    // 应用里 SwiftUI 不做启动呈现（defaultLaunchBehavior 只有 suppressed 一档
    // 增量），而菜单 extra 内容视图首次点开才挂载、launch intent 挂不上；切到
    // regular 后交给普通应用的默认行为——启动呈现 Window scene。
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)

    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification, object: nil)
    center.addObserver(
      self, selector: #selector(appOcclusionDidChange(_:)),
      name: NSApplication.didChangeOcclusionStateNotification, object: nil)
  }

  /// 关窗回纯后台后再经菜单 ⑦ / Dock reopen 开窗的入场：任意路径让主窗口
  /// 可见都进前台形态。只进不出：窗口被完全遮挡或 Cmd+H 也会短暂失去
  /// .visible，但那只意味着「不该退」，退场由 willClose 普查负责；多切一次
  /// .regular 是幂等的。
  @objc private func appOcclusionDidChange(_ notification: Notification) {
    let hasVisibleWindow = NSApp.windows.contains { $0.isVisible && $0.canBecomeMain }
    guard hasVisibleWindow, NSApp.activationPolicy() != .regular else { return }
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
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
