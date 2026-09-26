import Foundation

// MARK: - 运行时失败事实的呈现（RuntimeFailureFacts / AgentRunState / 系统代理应用态）

extension AppPresentation {
  static func message(for failure: RuntimeFailureFacts) -> String {
    switch failure {
    case .firewallBlocked(let facts):
      return
        "macOS 防火墙已阻止 \(facts.executableName) 接受传入连接。请在系统设置中允许传入连接。"
    case .launch(let facts): return launchFailure(facts)
    case .service(let facts): return serviceFailure(facts)
    case .activation(let error): return activation(error)
    case .requiresApproval: return "请在系统设置的登录项中允许代理后台服务"
    case .systemProxy(let facts): return systemProxyFailure(facts)
    }
  }

  static func message(for state: ProxyRuntimeController.AgentRunState) -> String {
    switch state {
    case .off: return "代理未运行"
    case .starting: return "代理正在启动"
    case .running: return "代理运行中"
    case .firewallBlocked(let facts):
      return message(for: RuntimeFailureFacts.firewallBlocked(facts))
    case .launchFailed(let facts): return message(for: RuntimeFailureFacts.launch(facts))
    case .requiresApproval: return message(for: RuntimeFailureFacts.requiresApproval)
    case .serviceFailed(let facts): return message(for: RuntimeFailureFacts.service(facts))
    }
  }

  static func message(for application: SystemProxyApplicationFacts) -> String {
    switch application {
    case .idle: return "系统代理未接管"
    case .pending: return "系统代理待应用：等待代理就绪或可用出口"
    case .applied: return "系统代理已应用"
    case .failed(let facts): return systemProxyFailure(facts)
    }
  }

  private static func launchFailure(_ facts: LaunchFailureFacts) -> String {
    switch facts {
    case .missingRuntimeDocument: return "缺少运行时文档"
    case .localEndpoint(let endpoint, let host, let port, let cause):
      return "本地代理 \(endpoint.uppercased()) 端点 \(host):\(port) 未就绪（\(endpointFailure(cause))）"
    case .pacEndpoint(let port, let cause):
      return "PAC 端点端口 \(port) 未就绪（\(endpointFailure(cause))）"
    case .unreadableSettings: return "本地代理配置无法读取，已停止代理以避免静默改用出厂端口"
    }
  }

  private static func serviceFailure(_ facts: ServiceFailureFacts) -> String {
    switch facts {
    case .runtimeFile: return "运行时文件读写失败"
    case .agent: return "代理后台服务管理失败"
    case .missingDocument: return "缺少运行时文档"
    case .persistence: return "代理运行状态保存失败"
    case .unknown: return unknownError
    }
  }

  private static func systemProxyFailure(_ facts: SystemProxyFailureFacts) -> String {
    switch facts {
    case .operation(let failure): return systemProxy(failure)
    case .mode(let error): return proxyMode(error)
    case .ownershipConflict: return "系统代理配置已被其他设置改动，未覆盖"
    case .unknown: return "系统代理未能应用"
    }
  }

  // swiftlint:disable:next cyclomatic_complexity
  private static func systemProxy(_ failure: SystemProxyOperationFailure) -> String {
    switch failure {
    case .authorizationFailed: return "没有获得修改系统代理所需的授权"
    case .preferencesUnavailable: return "系统网络配置不可用"
    case .preferencesBusy: return "系统网络配置正被其他设置操作占用"
    case .noCurrentNetworkSet: return "没有当前网络位置"
    case .noProxyServices: return "当前网络位置没有可写入的网络服务"
    case .unreadableService: return "无法读取网络服务的代理配置"
    case .invalidStoredConfiguration: return "保存的系统代理配置无效"
    case .cannotWriteService: return "无法写入网络服务的代理配置"
    case .commitFailed: return "系统代理提交失败"
    case .applyFailed: return "系统代理应用失败"
    case .ownershipStoreFailed: return "系统代理所有权记录失败"
    }
  }

  private static func endpointFailure(_ outcome: RuntimeEndpointFailure) -> String {
    switch outcome {
    case .refused: return "连接被拒绝"
    case .timedOut: return "连接超时"
    case .invalidResponse: return "响应无效"
    case .unknown: return "状态无法确定"
    }
  }
}
