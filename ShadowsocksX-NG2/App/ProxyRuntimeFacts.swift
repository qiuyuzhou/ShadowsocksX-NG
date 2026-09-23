import Foundation

/// Stable runtime status categories exposed to app presentation surfaces.
enum ProxyRuntimeStatus: Equatable, Sendable {
  case off
  case starting
  case running
  case firewallBlocked
  case launchFailed
  case activationFailed
  case requiresApproval
  case serviceFailed
  case systemProxyFailed
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
enum RuntimeFailureFacts: Error, Equatable, Sendable {
  case firewallBlocked(FirewallBlockedFacts)
  case launch(LaunchFailureFacts)
  case service(ServiceFailureFacts)
  case activation(ActivationFailure)
  case requiresApproval
  case systemProxy(SystemProxyFailureFacts)
}

extension ProxyRuntimeFacts {
  init(state: ProxyRuntimeController.ProxyState) {
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
    case .activationFailed(let failure):
      self.init(status: .activationFailed, isOn: false, failure: .activation(failure))
    case .requiresApproval:
      self.init(status: .requiresApproval, isOn: true, failure: .requiresApproval)
    case .serviceFailed(let facts):
      self.init(status: .serviceFailed, isOn: false, failure: .service(facts))
    case .systemProxyFailed(let facts):
      self.init(status: .systemProxyFailed, isOn: true, failure: .systemProxy(facts))
    }
  }
}
