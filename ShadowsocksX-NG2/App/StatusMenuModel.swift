import Foundation

/// 状态菜单八项白名单的呈现模型（spec #21 D11，issue #31）：从运行状态、
/// 模式、目录树与监听设置派生菜单数据。不持有 AppKit 类型，纯逻辑可测；
/// 视觉与交互细节（勾选标记、禁用态）在 ProxyStatusMenu 呈现，不建自动测试。
enum StatusMenuModel {
  /// 头部状态摘要：运行状态、当前模式、活动目标（含点名失败细节）。
  struct Summary: Equatable {
    /// 代理开关的当前意图：true 为已开（菜单项呈现「停止代理」）。
    let isOn: Bool
    let status: String
    /// 启动/激活/系统代理失败的点名原因，随状态摘要一并呈现。
    let detail: String?
    let modeLabel: String
    /// 活动目标从根到节点的显示名路径；未激活为 nil。
    let targetPath: String?
  }

  /// 运行状态 → 摘要映射（与主窗口诊断区口径一致）。
  static func summary(
    state: ProxyRuntimeController.ProxyState,
    mode: ProxyMode,
    targetPath: String?
  ) -> Summary {
    let status: String
    let detail: String?
    switch state {
    case .off:
      status = "代理未运行"
      detail = nil
    case .starting:
      status = "正在启动代理…"
      detail = nil
    case .running:
      status = "代理运行中"
      detail = nil
    case .firewallBlocked(let reason):
      status = "代理运行中（局域网受阻）"
      detail = reason
    case .launchFailed(let reason):
      status = "启动失败"
      detail = reason
    case .activationFailed(let reason):
      status = "无法启动"
      detail = reason
    case .requiresApproval:
      status = "等待允许后台代理"
      detail = "请在系统设置-登录项中允许 ShadowsocksX-NG 后台项"
    case .serviceFailed(let reason):
      status = "服务管理失败"
      detail = reason
    case .systemProxyFailed(let reason):
      status = "系统代理未应用"
      detail = reason
    }
    return Summary(
      isOn: state.isOn, status: status, detail: detail, modeLabel: mode.label,
      targetPath: targetPath)
  }

  /// 复制 HTTP 导出行（D11）：shell 可直接 source 的 http/https 双导出；
  /// HTTP 入站未启用时无行可复制（菜单项禁用）。地址取监听范围的对外地址
  /// （回环态 127.0.0.1，主机态为对外公布地址），与 PAC 语义一致。
  static func httpExportLine(settings: SslocalListenSettings) -> String? {
    guard settings.httpProxyEnabled else { return nil }
    let endpoint = "http://\(settings.scope.advertisedAddress):\(settings.httpPort)"
    return "export http_proxy=\(endpoint);export https_proxy=\(endpoint);"
  }

  /// 活动目标的显示名路径（根 → 节点，" / " 连接）；基于目录树 projection
  /// 派生（issue #41）。未激活或目标已不在树中为 nil。
  static func targetPath(in nodes: [CatalogTreeNode], activeTargetID: NodeID?) -> String? {
    guard let activeTargetID else { return nil }
    var path: [String] = []
    func search(_ node: CatalogTreeNode) -> Bool {
      if node.id == activeTargetID {
        path.append(node.name)
        return true
      }
      for child in node.children ?? [] where search(child) {
        path.insert(node.name, at: 0)
        return true
      }
      return false
    }
    for node in nodes where search(node) { break }
    return path.isEmpty ? nil : path.joined(separator: " / ")
  }
}
