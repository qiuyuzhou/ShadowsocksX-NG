import AppKit
import SwiftUI

/// 状态菜单的代理控制区（spec #21 D11 白名单中本票的子集）：头部状态摘要、
/// 代理开关与「启动失败」呈现。模式选择、活动目标级联等项由后续工单接入。
struct ProxyStatusMenu: View {
  private struct Presentation {
    let isOn: Bool
    let status: String
    let detail: String?
  }

  @Environment(\.openWindow) private var openWindow
  @ObservedObject var controller: ProxyRuntimeController

  var body: some View {
    let presentation = presentation
    Text(presentation.status)

    Divider()

    Button(presentation.isOn ? "停止代理" : "启动代理") {
      Task { await controller.setProxyEnabled(!presentation.isOn) }
    }

    if let failure = presentation.detail {
      Text(failure)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    if let pacURL = controller.pacURL {
      Button("复制 PAC URL") {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(pacURL.absoluteString, forType: .string)
      }
    }

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

  private var presentation: Presentation {
    switch controller.state {
    case .off:
      return Presentation(isOn: false, status: "代理未运行", detail: nil)
    case .starting:
      return Presentation(isOn: true, status: "正在启动代理…", detail: nil)
    case .running:
      return Presentation(isOn: true, status: "代理运行中", detail: nil)
    case .firewallBlocked(let detail):
      return Presentation(isOn: true, status: "代理运行中（局域网受阻）", detail: detail)
    case .launchFailed(let detail):
      return Presentation(isOn: false, status: "启动失败", detail: detail)
    case .activationFailed(let reason):
      return Presentation(isOn: false, status: "无法启动", detail: reason)
    case .requiresApproval:
      return Presentation(
        isOn: true,
        status: "等待允许后台代理",
        detail: "请在系统设置-登录项中允许 ShadowsocksX-NG 后台项")
    case .serviceFailed(let detail):
      return Presentation(isOn: false, status: "服务管理失败", detail: detail)
    case .systemProxyFailed(let detail):
      return Presentation(isOn: true, status: "系统代理未应用", detail: detail)
    }
  }
}
