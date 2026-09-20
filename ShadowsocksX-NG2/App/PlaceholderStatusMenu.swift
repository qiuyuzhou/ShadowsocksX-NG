import AppKit
import SwiftUI

/// 占位状态菜单，由后续工单替换为真实的代理控制菜单。
struct PlaceholderStatusMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text("代理未运行（占位状态）")

        Divider()

        Button("打开主窗口…") {
            NSApp.activate()
            openWindow(id: "main")
        }

        Divider()

        Button("退出 ShadowsocksX-NG 2.0") {
            NSApp.terminate(nil)
        }
    }
}
