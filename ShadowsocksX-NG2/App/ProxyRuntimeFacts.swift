import Foundation

/// Stable runtime status categories exposed to app presentation surfaces.
/// 系统代理结果不在此列：它有独立的 `SystemProxyApplicationFacts`
/// （issue #60 拆分两个状态面）。
enum ProxyRuntimeStatus: Equatable, Sendable {
  case off
  case starting
  case running
  case firewallBlocked
  case launchFailed
  case requiresApproval
  case serviceFailed
}

/// Domain-neutral runtime projection for status-menu presentation. The
/// controller's state representation stays behind the adapter below.
struct ProxyRuntimeFacts: Equatable, Sendable {
  let status: ProxyRuntimeStatus
  let isOn: Bool
  let failure: RuntimeFailureFacts?

  init(
    status: ProxyRuntimeStatus,
    isOn: Bool,
    failure: RuntimeFailureFacts? = nil
  ) {
    self.status = status
    self.isOn = isOn
    self.failure = failure
  }
}

/// 系统代理实际作用的固定类别（issue #60）：意图持久化为开关事实，这里
/// 呈现 NG2 对系统设置的真实作用，与 agent 运行状态互不代替。
enum SystemProxyApplicationFacts: Equatable, Sendable {
  /// 意图关闭：NG2 不持有系统设置。
  case idle
  /// 意图开启，等待 agent 健康或可用出口；条件恢复后自动收敛。
  case pending
  /// 已写入系统设置且持续持有。
  case applied
  /// 写入或恢复失败（typed）。
  case failed(SystemProxyFailureFacts)
}

/// Safe endpoint health categories used by runtime state and presentation.
enum RuntimeEndpointFailure: Equatable, Sendable {
  case refused
  case timedOut
  case invalidResponse
  case unknown
}

struct FirewallBlockedFacts: Equatable, Sendable {
  let executableName: String
}

enum LaunchFailureFacts: Equatable, Sendable {
  case missingRuntimeDocument
  case localEndpoint(
    endpoint: String, host: String, port: Int, cause: RuntimeEndpointFailure)
  case pacEndpoint(port: Int, cause: RuntimeEndpointFailure)
  case unreadableSettings
}

enum ServiceFailureFacts: Equatable, Sendable {
  case runtimeFile
  case agent
  case missingDocument
  case persistence
  case unknown
}

enum SystemProxyOperationFailure: Equatable, Sendable {
  case authorizationFailed
  case preferencesUnavailable
  case preferencesBusy
  case noCurrentNetworkSet
  case noProxyServices
  case unreadableService
  case invalidStoredConfiguration
  case cannotWriteService
  case commitFailed
  case applyFailed
  case ownershipStoreFailed
}

enum SystemProxyFailureFacts: Equatable, Sendable {
  case operation(SystemProxyOperationFailure)
  case mode(ProxyModeError)
  case ownershipConflict
  case unknown
}

/// Structured runtime failure projection used by runtime synchronization and
/// app presentation. No arbitrary platform detail is carried into this state.
/// `.systemProxy` 只用于把系统代理失败携带进结构化 outcome（设置工作流与
/// 目录收敛结果）；呈现面走 `SystemProxyApplicationFacts.failed`。
enum RuntimeFailureFacts: Error, Equatable, Sendable {
  case firewallBlocked(FirewallBlockedFacts)
  case launch(LaunchFailureFacts)
  case service(ServiceFailureFacts)
  case activation(ActivationFailure)
  case requiresApproval
  case systemProxy(SystemProxyFailureFacts)
}

extension ProxyRuntimeFacts {
  init(state: ProxyRuntimeController.AgentRunState) {
    switch state {
    case .off:
      self.init(status: .off, isOn: false)
    case .starting:
      self.init(status: .starting, isOn: true)
    case .running:
      self.init(status: .running, isOn: true)
    case .firewallBlocked(let facts):
      self.init(
        status: .firewallBlocked, isOn: true, failure: .firewallBlocked(facts))
    case .launchFailed(let facts):
      self.init(status: .launchFailed, isOn: false, failure: .launch(facts))
    case .requiresApproval:
      self.init(status: .requiresApproval, isOn: true, failure: .requiresApproval)
    case .serviceFailed(let facts):
      self.init(status: .serviceFailed, isOn: false, failure: .service(facts))
    }
  }
}
