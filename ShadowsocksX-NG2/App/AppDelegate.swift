import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    /// LSUIElement 菜单栏形态的硬性要求：关闭最后一个窗口后进程必须保留。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
