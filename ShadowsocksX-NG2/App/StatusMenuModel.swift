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
      isOn: isOn(state: state), status: status, detail: detail, modeLabel: mode.label,
      targetPath: targetPath)
  }

  /// 代理开关的当前意图（菜单开关与全局快捷键共用的同一判定）：启动失败等
  /// 中间态视为未开——两个入口的下一步动作都是「启动」。
  static func isOn(state: ProxyRuntimeController.ProxyState) -> Bool {
    switch state {
    case .off, .launchFailed, .activationFailed, .serviceFailed:
      false
    case .starting, .running, .firewallBlocked, .requiresApproval, .systemProxyFailed:
      true
    }
  }

  /// 复制 HTTP 导出行（D11）：shell 可直接 source 的 http/https 双导出；
  /// HTTP 入站未启用时无行可复制（菜单项禁用）。地址取监听范围的对外地址
  /// （回环态 127.0.0.1，主机态为对外公布地址），与 PAC 语义一致。
  static func httpExportLine(settings: SslocalListenSettings) -> String? {
    guard settings.httpProxyEnabled else { return nil }
    let endpoint = "http://\(settings.scope.advertisedAddress):\(settings.httpPort)"
    return "export http_proxy=\(endpoint);export https_proxy=\(endpoint);"
  }

  /// 全局快捷键「切换模式」的循环序：仅内置三模式参与；外部 PAC 的 URL 只能
  /// 在设置区配置（#33），不进循环——快捷键从外部 PAC 回到第一个可用内置模式。
  static func nextMode(
    after mode: ProxyMode,
    availableModes: Set<ProxyModeKind> = ProxySettings.defaultEnabledModes
  ) -> ProxyMode {
    let cycle = [ProxyModeKind.pac, .global, .manual].filter(availableModes.contains)
    guard !cycle.isEmpty else { return mode }
    guard let currentIndex = cycle.firstIndex(of: mode.kind) else {
      return proxyMode(for: cycle[0])
    }
    return proxyMode(for: cycle[(currentIndex + 1) % cycle.count])
  }

  private static func proxyMode(for kind: ProxyModeKind) -> ProxyMode {
    switch kind {
    case .pac: .pac
    case .global: .global
    case .manual: .manual
    case .externalPAC: .pac
    }
  }

  /// 活动目标级联子菜单的只读树快照：结构与配置树一致（含停用节点），活动
  /// 目标以勾选呈现。分组节点持有子树，服务器叶子无子。`id` 供 SwiftUI
  /// ForEach 稳定标识（导入不去重，同名兄弟节点合法）。
  struct TargetNode: Equatable {
    let id: NodeID
    let name: String
    let isGroup: Bool
    let isActive: Bool
    let children: [TargetNode]
  }

  static func targetTree(
    catalog: ConfigurationCatalog,
    activeTargetID: NodeID?
  ) -> [TargetNode] {
    targetChildren(of: nil, catalog: catalog, activeTargetID: activeTargetID)
  }

  /// 活动目标的显示名路径（根 → 节点，" / " 连接）；未激活或目标已不在目录
  /// 中为 nil。
  static func targetPath(catalog: ConfigurationCatalog, activeTargetID: NodeID?) -> String? {
    guard let activeTargetID, catalog.contains(activeTargetID) else { return nil }
    let chain = catalog.ancestors(of: activeTargetID).reversed() + [activeTargetID]
    return chain.map { displayName(catalog: catalog, id: $0) }.joined(separator: " / ")
  }

  private static func targetChildren(
    of parent: NodeID?,
    catalog: ConfigurationCatalog,
    activeTargetID: NodeID?
  ) -> [TargetNode] {
    let ids = (try? catalog.children(of: parent)) ?? []
    return ids.compactMap { id in
      guard let entry = catalog.entry(for: id) else { return nil }
      let isGroup: Bool = {
        if case .group = entry.kind { return true }
        return false
      }()
      return TargetNode(
        id: id,
        name: displayName(catalog: catalog, id: id),
        isGroup: isGroup,
        isActive: id == activeTargetID,
        children: isGroup
          ? targetChildren(of: id, catalog: catalog, activeTargetID: activeTargetID)
          : [])
    }
  }

  /// 行显示名：委托目录条目的共用口径（`CatalogEntry.displayName`）。
  private static func displayName(catalog: ConfigurationCatalog, id: NodeID) -> String {
    catalog.entry(for: id)?.displayName ?? ""
  }
}
