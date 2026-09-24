import AppKit
import SwiftUI

/// 组合根持有的 workspace 开窗器：主窗口是 AppKit 拥有的 NSWindow，内容为
/// SwiftUI 主 workspace（NSHostingView）。此前经 SwiftUI `Window` scene +
/// `openWindow` 开窗，但该环境值在 MenuBarExtra 上下文（无论标签还是内容）
/// 实测不产生窗口，SwiftUI 对 LSUIElement 应用也不做场景启动呈现——「每次
/// 启动呈现主窗口」必须由 AppKit 直控，不依赖场景挂载时序。窗口关闭时只
/// orderOut 不释放（isReleasedWhenClosed = false），重开即复用，workspace
/// 内部导航状态得以保留。
@MainActor
final class WorkspaceWindowOpeningAdapter: WorkspaceWindowOpening {
  static let workspaceWindowID = NSUserInterfaceItemIdentifier("main")

  private var window: NSWindow?
  private let makeContentView: () -> NSView

  /// 内容视图由组合根惰性构造：主窗口内的 SwiftUI 状态只在首次开窗时创建。
  init(makeContentView: @escaping () -> NSView) {
    self.makeContentView = makeContentView
  }

  func ensureWorkspaceVisible() {
    NSApp.activate(ignoringOtherApps: true)
    let window = self.window ?? makeWindow()
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow() -> NSWindow {
    let window = NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 960, height: 640),
      styleMask: [.titled, .closable, .miniaturizable, .resizable],
      backing: .buffered, defer: false)
    window.title = "ShadowsocksX-NG 2.0"
    window.identifier = Self.workspaceWindowID
    window.isReleasedWhenClosed = false
    window.contentView = makeContentView()
    window.center()
    self.window = window
    return window
  }
}
