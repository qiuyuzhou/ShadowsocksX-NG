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
    NSApp.activate(ignoringOtherApps: true)
    openWindow(id: Self.workspaceWindowID)
  }
}
