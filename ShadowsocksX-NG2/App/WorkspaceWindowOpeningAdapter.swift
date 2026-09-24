import AppKit
import SwiftUI

/// 组合根使用的 workspace 开窗 adapter。scene ID 与 AppKit activation effect
/// 只在此 focused adapter 与 MainApp scene declaration 中出现。
@MainActor
struct WorkspaceWindowOpeningAdapter: WorkspaceWindowOpening {
  static let workspaceWindowID = "main"

  private let openWindow: OpenWindowAction

  init(openWindow: OpenWindowAction) {
    self.openWindow = openWindow
  }

  func ensureWorkspaceVisible() {
    // 混合形态契约（CONTEXT.md「Foreground form」不变量）：主 workspace 可见
    // 期间以普通应用呈现，Dock 图标随窗口出现；最后一个窗口关闭后由
    // AppDelegate 切回纯后台形态。LSUIElement 保证启动即静默。
    NSApp.setActivationPolicy(.regular)
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: Self.workspaceWindowID)
  }
}
