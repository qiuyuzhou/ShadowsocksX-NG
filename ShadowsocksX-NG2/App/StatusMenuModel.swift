import Foundation

/// 状态菜单的呈现模型（spec #21 D11，issue #31/#47/#60）：从代理控制工作流
/// 的整体 snapshot 派生菜单数据。agent 与系统代理是两个独立状态面；不持有
/// AppKit 类型，纯逻辑可测；视觉与交互细节（勾选标记、禁用态）在
/// ProxyStatusMenu 呈现，不建自动测试。
enum StatusMenuModel {
  /// 头部状态摘要：agent 运行状态、当前模式、活动目标（含点名失败细节）与
  /// 系统代理实际应用状态。
  struct Summary: Equatable {
    /// Agent 开关意图（开关勾选态的绑定来源）。
    let agentIntentEnabled: Bool
    /// Agent 运行状态的「在跑」投影。
    let isOn: Bool
    /// Agent 运行状态文本。
    let status: String
    /// Agent 侧点名原因：运行失败或激活拒绝/目标清除（独立于运行状态）。
    let detail: String?
    /// 系统代理开关意图（开关勾选态的绑定来源）。
    let systemProxyIntentEnabled: Bool
    /// 系统代理实际应用状态文本（与 agent 运行状态分开呈现）。
    let systemProxyStatus: String
    /// 同上但不带「系统代理：」前缀（首页等已有上下文的呈现面用）。
    let systemProxyStateLabel: String
    /// 系统代理写入/恢复失败的点名原因；非失败态为 nil。
    let systemProxyDetail: String?
    let modeLabel: String
    /// 活动目标从根到节点的显示名路径；未激活为 nil。
    let targetPath: String?
  }

  /// 运行状态 → 摘要映射（与主窗口诊断区口径一致）：输入是代理控制工作流
  /// 的整体 snapshot（issue #47/#60），菜单不再拆装控制器或运行时字段。
  static func summary(from snapshot: ProxyControlSnapshot) -> Summary {
    let status: String
    switch snapshot.runtime.status {
    case .off:
      status = "代理未运行"
    case .starting:
      status = "正在启动代理…"
    case .running:
      status = "代理运行中"
    case .firewallBlocked:
      status = "代理运行中（局域网受阻）"
    case .launchFailed:
      status = "启动失败"
    case .requiresApproval:
      status = "等待允许后台代理"
    case .serviceFailed:
      status = "服务管理失败"
    }
    let agentDetail =
      snapshot.runtime.failure.map { AppPresentation.message(for: $0) }
      ?? snapshot.activationFailure.map { AppPresentation.message(for: $0) }
    let stateLabel: String
    let systemProxyDetail: String?
    switch snapshot.systemProxyApplication {
    case .idle:
      stateLabel = "未接管"
      systemProxyDetail = nil
    case .pending:
      stateLabel = "待应用"
      systemProxyDetail = nil
    case .applied:
      stateLabel = "已应用"
      systemProxyDetail = nil
    case .failed(let facts):
      stateLabel = "应用失败"
      systemProxyDetail = AppPresentation.message(for: RuntimeFailureFacts.systemProxy(facts))
    }
    return Summary(
      agentIntentEnabled: snapshot.agentIntentEnabled,
      isOn: snapshot.runtime.isOn,
      status: status,
      detail: agentDetail,
      systemProxyIntentEnabled: snapshot.systemProxyIntentEnabled,
      systemProxyStatus: "系统代理：\(stateLabel)",
      systemProxyStateLabel: stateLabel,
      systemProxyDetail: systemProxyDetail,
      modeLabel: snapshot.proxyMode.label,
      targetPath: snapshot.activeTarget?.pathSummary)
  }
}
