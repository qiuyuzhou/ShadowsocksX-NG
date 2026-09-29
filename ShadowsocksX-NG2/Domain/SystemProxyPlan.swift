import Foundation

/// System proxy write failures shared by the pure planner and SystemConfiguration adapter.
enum SystemProxyError: Error, Equatable, Sendable {
  case authorizationFailed(Int32)
  case preferencesUnavailable
  case preferencesBusy
  case noCurrentNetworkSet
  case noNetworkLocations
  case noProxyServices
  case unreadableService(String)
  case invalidStoredConfiguration(String)
  case cannotWriteService(String)
  case commitFailed(String)
  case applyFailed(String)
  case endpointSignatureStoreFailed(String)
}

/// A service identity includes its network location because service IDs can appear in
/// different locations during cleanup-all-locations scans.
struct SystemProxyServiceIdentifier: Equatable, Hashable, Sendable {
  let locationID: String
  let serviceID: String
}

/// One service's complete Proxies dictionary as a pure value.
struct SystemProxyServiceState: Equatable, Sendable {
  let identifier: SystemProxyServiceIdentifier
  /// `nil` means that the service has no Proxies entity configuration.
  let configuration: Data?
}

/// One planned Proxies-entity write. `nil` clears the complete entity.
struct SystemProxyPlannedWrite: Equatable, Sendable {
  let identifier: SystemProxyServiceIdentifier
  let configuration: Data?
}

/// Result of an apply plan. `unchanged` avoids an unnecessary SCPreferences commit.
enum SystemProxyWriteOutcome: Equatable, Sendable {
  case written
  case unchanged
}

/// Persisted cleanup selector. This records the last endpoint signature NG2 attempted,
/// not a snapshot and not proof that NG2 exclusively owns matching values.
struct SystemProxyEndpointSignature: Codable, Equatable, Sendable {
  struct Endpoint: Codable, Equatable, Hashable, Sendable {
    let host: String
    let port: Int
  }

  let socks: Endpoint
  let http: Endpoint

  init(configuration: SystemProxyConfiguration) {
    socks = Endpoint(host: configuration.socks.host, port: configuration.socks.port)
    http = Endpoint(host: configuration.http.host, port: configuration.http.port)
  }

  init(socks: Endpoint, http: Endpoint) {
    self.socks = socks
    self.http = http
  }

  var isValid: Bool {
    !socks.host.isEmpty && !http.host.isEmpty
      && (1...65_535).contains(socks.port)
      && (1...65_535).contains(http.port)
  }

  /// Cleanup requires the enabled SOCKS, HTTP, and HTTPS endpoints to match exactly.
  func matches(_ dictionary: [String: Any]) -> Bool {
    Self.enabled(dictionary[SystemProxyPropertyList.socksEnabled])
      && Self.enabled(dictionary[SystemProxyPropertyList.httpEnabled])
      && Self.enabled(dictionary[SystemProxyPropertyList.httpsEnabled])
      && dictionary[SystemProxyPropertyList.socksProxy] as? String == socks.host
      && Self.port(dictionary[SystemProxyPropertyList.socksPort]) == socks.port
      && dictionary[SystemProxyPropertyList.httpProxy] as? String == http.host
      && Self.port(dictionary[SystemProxyPropertyList.httpPort]) == http.port
      && dictionary[SystemProxyPropertyList.httpsProxy] as? String == http.host
      && Self.port(dictionary[SystemProxyPropertyList.httpsPort]) == http.port
  }

  private static func enabled(_ value: Any?) -> Bool {
    port(value) == 1
  }

  private static func port(_ value: Any?) -> Int? {
    if let value = value as? Int { return value }
    return (value as? NSNumber)?.intValue
  }
}

/// Pure configuration planning. Apply rewrites every differing service in the active
/// location. Cleanup matches endpoint signatures across locations and clears the entire
/// matching Proxies dictionary.
enum SystemProxyPlanner {
  struct ApplyPlan: Equatable, Sendable {
    let writes: [SystemProxyPlannedWrite]

    var outcome: SystemProxyWriteOutcome {
      writes.isEmpty ? .unchanged : .written
    }
  }

  struct ClearPlan: Equatable, Sendable {
    let writes: [SystemProxyPlannedWrite]
  }

  static func makeApplyPlan(
    services: [SystemProxyServiceState], configuration: SystemProxyConfiguration
  ) throws -> ApplyPlan {
    var writes: [SystemProxyPlannedWrite] = []
    for service in services {
      let original = try dictionary(
        from: service.configuration, serviceID: service.identifier.serviceID)
      let desired = try propertyListData(
        from: SystemProxyPropertyList.applying(configuration, to: original),
        serviceID: service.identifier.serviceID)
      guard !equivalent(service.configuration, desired) else { continue }
      writes.append(SystemProxyPlannedWrite(identifier: service.identifier, configuration: desired))
    }
    return ApplyPlan(writes: writes)
  }

  static func makeClearPlan(
    services: [SystemProxyServiceState], signature: SystemProxyEndpointSignature
  ) throws -> ClearPlan {
    let writes = try services.compactMap { service -> SystemProxyPlannedWrite? in
      let dictionary = try dictionary(
        from: service.configuration, serviceID: service.identifier.serviceID)
      guard signature.matches(dictionary) else { return nil }
      return SystemProxyPlannedWrite(identifier: service.identifier, configuration: nil)
    }
    return ClearPlan(writes: writes)
  }

  /// Property-list semantic equality; dictionary key order does not matter.
  static func equivalent(_ lhs: Data?, _ rhs: Data?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    guard
      let left = try? PropertyListSerialization.propertyList(from: lhs, options: [], format: nil)
        as? NSDictionary,
      let right = try? PropertyListSerialization.propertyList(from: rhs, options: [], format: nil)
        as? NSDictionary
    else { return lhs == rhs }
    return left.isEqual(right)
  }

  static func dictionary(from data: Data?, serviceID: String) throws -> [String: Any] {
    guard let data else { return [:] }
    guard
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil),
      let dictionary = propertyList as? [String: Any]
    else { throw SystemProxyError.invalidStoredConfiguration(serviceID) }
    return dictionary
  }

  static func propertyListData(from dictionary: [String: Any], serviceID: String) throws -> Data {
    do {
      return try PropertyListSerialization.data(
        fromPropertyList: dictionary, format: .binary, options: 0)
    } catch {
      throw SystemProxyError.unreadableService(serviceID)
    }
  }
}
