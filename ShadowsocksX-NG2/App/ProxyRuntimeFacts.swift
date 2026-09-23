import Foundation

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
  case externalPAC(RuntimeEndpointFailure)
  case ownershipConflict
  case unknown
}

/// Structured runtime failure projection used by catalog synchronization. No
/// arbitrary platform detail is carried into this UI-facing state.
enum RuntimeFailureFacts: Error, Equatable, Sendable {
  case launch(LaunchFailureFacts)
  case service(ServiceFailureFacts)
  case activation(ActivationFailure)
  case systemProxy(SystemProxyFailureFacts)
}
