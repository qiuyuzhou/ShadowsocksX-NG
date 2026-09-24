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
      styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
      backing: .buffered, defer: false)
    window.title = "ShadowsocksX-NG 2.0"
    window.titlebarAppearsTransparent = true
    window.identifier = Self.workspaceWindowID
    window.isReleasedWhenClosed = false
    // SwiftUI scene 窗口的 chrome 需在此手动补齐，两件缺一不可：
    // ① 空 NSToolbar + .unified：NavigationSplitView 桥接把侧栏切换按钮与
    //    toolbar item 装进真实工具栏，并给内容正确安全区。没有工具栏时桥接
    //    只装一半——玻璃背景画进内容区顶部而内容不缩进，分区大标题被糊成
    //    色块。
    // ② .fullSizeContentView + titlebarAppearsTransparent：侧栏通顶、窗口
    //    标题呈现在内容区前缘（scene 版外观）。缺省标题栏会把标题挤在
    //    红绿灯旁截断成「ShadowsocksX-N…」。
    let toolbar = NSToolbar(identifier: "workspace")
    window.toolbar = toolbar
    window.toolbarStyle = .unified
    window.contentView = makeContentView()
    window.center()
    self.window = window
    return window
  }
}
