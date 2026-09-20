import AppKit
import SwiftUI

/// 状态菜单的代理控制区（spec #21 D11 白名单中本票的子集）：头部状态摘要、
/// 代理开关与「启动失败」呈现。模式选择、活动目标级联等项由后续工单接入。
struct ProxyStatusMenu: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var controller: ProxyRuntimeController

  var body: some View {
    Text(statusSummary)

    Divider()

    Button(proxyOn ? "停止代理" : "启动代理") {
      Task { await controller.setProxyEnabled(!proxyOn) }
    }

    if let failure = failureSummary {
      Text(failure)
        .font(.caption)
        .foregroundStyle(.secondary)
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

  private var proxyOn: Bool {
    switch controller.state {
    case .off, .launchFailed, .activationFailed, .serviceFailed:
      return false
    case .starting, .running, .requiresApproval:
      return true
    }
  }

  private var statusSummary: String {
    switch controller.state {
    case .off:
      return "代理未运行"
    case .starting:
      return "正在启动代理…"
    case .running:
      return "代理运行中"
    case .launchFailed:
      return "启动失败"
    case .activationFailed:
      return "无法启动"
    case .requiresApproval:
      return "等待允许后台代理"
    case .serviceFailed:
      return "服务管理失败"
    }
  }

  private var failureSummary: String? {
    switch controller.state {
    case .launchFailed(let detail):
      return detail
    case .activationFailed(let reason):
      return reason
    case .serviceFailed(let detail):
      return detail
    case .requiresApproval:
      return "请在系统设置-登录项中允许 ShadowsocksX-NG 后台项"
    case .off, .starting, .running:
      return nil
    }
  }
}
