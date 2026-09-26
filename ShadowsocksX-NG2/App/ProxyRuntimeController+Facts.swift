import Foundation

// MARK: - 只读事实投影与静态缝

extension ProxyRuntimeController {
  var isActiveTargetPresent: Bool { machine.activeTargetID != nil }

  /// Agent 开关意图（持久化事实；开关 UI 的绑定来源，issue #60）。
  var agentIntentEnabled: Bool { settings.agentEnabled }

  /// 系统代理开关意图（持久化事实；开关 UI 的绑定来源，issue #60）。
  var systemProxyIntentEnabled: Bool { settings.systemProxyEnabled }

  /// Stable app-facing projection for status-menu presentation. The menu does
  /// not depend on this controller's nested state representation.
  var runtimeFacts: ProxyRuntimeFacts {
    ProxyRuntimeFacts(state: state)
  }

  static var defaultFirewallExecutableURLs: [URL] {
    let bundle = Bundle.main.bundleURL
    return [
      bundle.appendingPathComponent("Contents/MacOS/ShadowsocksX-NG2Agent"),
      bundle.appendingPathComponent("Contents/Helpers/sslocal"),
    ]
  }

  /// 诊断只读面（issue #34）：当前监听设置；监听地址在导出中只以回环/非回环
  /// 两态呈现（D7）。
  var listenSettings: SslocalListenSettings { settings.listen }

  /// 当前已部署 runtime 的完整监听身份。已停止或启动失败时没有有效的
  /// runtime 例外，不能拿最后一次设置快照冒充仍在监听。
  var effectiveRuntimeListenFacts: RuntimeListenFacts? {
    let isListening: Bool
    switch state {
    case .running, .firewallBlocked:
      isListening = true
    case .off, .starting, .launchFailed, .requiresApproval, .serviceFailed:
      isListening = false
    }
    guard isListening, let lastDocument else { return nil }
    return RuntimeListenFacts(document: lastDocument)
  }

  /// 运行时契约的脱敏摘要（数量与协议元数据，D5）；契约缺失或无效返回 nil。
  /// 诊断导出不读契约内容，只携带此摘要。
  func runtimeDocumentSummary() -> String? {
    runtimeFileStore.loadDocument().map { Redactor.documentSummary($0) }
  }
}

extension ProxyRuntimeController.AgentRunState {
  /// Agent 运行状态的「在跑」投影（状态摘要与诊断口径）：启动失败等未运行
  /// 态视为未跑。
  var isOn: Bool {
    switch self {
    case .off, .launchFailed, .serviceFailed:
      false
    case .starting, .running, .firewallBlocked, .requiresApproval:
      true
    }
  }
}

extension ProxyRuntimeController: Activating {}

extension ProxyRuntimeController {
  static func makeProxyMode(from settings: ProxySettings) -> ProxyMode {
    ProxyMode.availableModes.first { $0.kind == settings.preferredMode } ?? .pac
  }
}
