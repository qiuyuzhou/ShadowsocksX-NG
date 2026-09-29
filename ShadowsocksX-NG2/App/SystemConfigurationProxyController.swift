import Foundation
import Security
import SystemConfiguration

/// System proxy write seam. The runtime health gate calls `apply` only while local
/// endpoints are usable. Clearing is declarative and never restores a prior snapshot.
@MainActor
protocol SystemProxyControlling {
  @discardableResult
  func apply(_ configuration: SystemProxyConfiguration) throws -> SystemProxyWriteOutcome
  func clearRecognizedSettings() throws
}

/// Writes NG2's proxy configuration to every service in the active network location.
/// Cleanup scans every location and clears the full Proxies entity for services that
/// match the last endpoint signature attempted by NG2.
@MainActor
final class SystemConfigurationProxyController: SystemProxyControlling {
  private struct ServiceSnapshot {
    let identifier: SystemProxyServiceIdentifier
    let networkService: SCNetworkService
    let proxyProtocol: SCNetworkProtocol?
    let configuration: Data?

    var plannerState: SystemProxyServiceState {
      SystemProxyServiceState(identifier: identifier, configuration: configuration)
    }
  }

  private let signatureStore: SystemProxyEndpointSignatureStoring

  init(
    signatureStore: SystemProxyEndpointSignatureStoring =
      FileSystemProxyEndpointSignatureStore()
  ) {
    self.signatureStore = signatureStore
  }

  func apply(_ configuration: SystemProxyConfiguration) throws -> SystemProxyWriteOutcome {
    try withPreferences { preferences in
      try lockPreferencesOrThrow(preferences)
      defer { SCPreferencesUnlock(preferences) }

      _ = try loadEndpointSignature()
      let services = try activeServiceSnapshots(in: preferences)
      guard !services.isEmpty else { throw SystemProxyError.noProxyServices }
      let plan = try SystemProxyPlanner.makeApplyPlan(
        services: services.map(\.plannerState), configuration: configuration)

      // Persist before the first SC write. A partial/failed apply is then recognizable
      // by a later OFF cleanup or by a retry after the health gate recovers.
      try saveEndpointSignature(SystemProxyEndpointSignature(configuration: configuration))

      guard !plan.writes.isEmpty else { return .unchanged }
      let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.identifier, $0) })
      for write in plan.writes {
        guard let service = servicesByID[write.identifier] else {
          throw SystemProxyError.cannotWriteService(write.identifier.serviceID)
        }
        if service.proxyProtocol == nil {
          _ = SCNetworkServiceAddProtocolType(service.networkService, kSCNetworkProtocolTypeProxies)
        }
        guard
          let proxyProtocol = service.proxyProtocol
            ?? SCNetworkServiceCopyProtocol(service.networkService, kSCNetworkProtocolTypeProxies),
          setConfiguration(write.configuration, on: proxyProtocol)
        else { throw SystemProxyError.cannotWriteService(write.identifier.serviceID) }
      }
      try commitAndApply(preferences)
      return .written
    }
  }

  func clearRecognizedSettings() throws {
    guard let signature = try loadEndpointSignature() else { return }
    try withPreferences { preferences in
      try lockPreferencesOrThrow(preferences)
      defer { SCPreferencesUnlock(preferences) }

      let services = try allServiceSnapshots(in: preferences)
      let plan = try SystemProxyPlanner.makeClearPlan(
        services: services.map(\.plannerState), signature: signature)
      guard !plan.writes.isEmpty else { return }

      let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.identifier, $0) })
      for write in plan.writes {
        guard let service = servicesByID[write.identifier],
          let proxyProtocol = service.proxyProtocol,
          setConfiguration(nil, on: proxyProtocol)
        else { throw SystemProxyError.cannotWriteService(write.identifier.serviceID) }
      }
      try commitAndApply(preferences)
    }
  }

  private func loadEndpointSignature() throws -> SystemProxyEndpointSignature? {
    do {
      return try signatureStore.load()
    } catch {
      throw SystemProxyError.endpointSignatureStoreFailed(String(describing: error))
    }
  }

  private func saveEndpointSignature(_ signature: SystemProxyEndpointSignature) throws {
    do {
      try signatureStore.save(signature)
    } catch {
      throw SystemProxyError.endpointSignatureStoreFailed(String(describing: error))
    }
  }

  private func activeServiceSnapshots(in preferences: SCPreferences) throws -> [ServiceSnapshot] {
    guard let set = SCNetworkSetCopyCurrent(preferences) else {
      throw SystemProxyError.noCurrentNetworkSet
    }
    guard let locationID = SCNetworkSetGetSetID(set) as String? else {
      throw SystemProxyError.noCurrentNetworkSet
    }
    return try serviceSnapshots(in: set, locationID: locationID)
  }

  private func allServiceSnapshots(in preferences: SCPreferences) throws -> [ServiceSnapshot] {
    guard let sets = SCNetworkSetCopyAll(preferences) as? [SCNetworkSet], !sets.isEmpty else {
      throw SystemProxyError.noNetworkLocations
    }
    return try sets.flatMap { set -> [ServiceSnapshot] in
      guard let locationID = SCNetworkSetGetSetID(set) as String? else {
        return [ServiceSnapshot]()
      }
      return try serviceSnapshots(in: set, locationID: locationID)
    }
  }

  private func serviceSnapshots(
    in set: SCNetworkSet, locationID: String
  ) throws -> [ServiceSnapshot] {
    guard let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
      return []
    }
    return try services.compactMap { service in
      guard let serviceID = SCNetworkServiceGetServiceID(service) as String? else { return nil }
      let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
      let configurationValue: CFPropertyList?
      if let proxyProtocol {
        configurationValue = SCNetworkProtocolGetConfiguration(proxyProtocol)
      } else {
        configurationValue = nil
      }
      return ServiceSnapshot(
        identifier: SystemProxyServiceIdentifier(
          locationID: locationID, serviceID: serviceID),
        networkService: service,
        proxyProtocol: proxyProtocol,
        configuration: try propertyListData(from: configurationValue, serviceID: serviceID))
    }
  }

  private func propertyListData(
    from value: CFPropertyList?, serviceID: String
  ) throws -> Data? {
    guard let value else { return nil }
    guard let dictionary = value as? [String: Any] else {
      throw SystemProxyError.unreadableService(serviceID)
    }
    return try SystemProxyPlanner.propertyListData(from: dictionary, serviceID: serviceID)
  }

  private func setConfiguration(_ data: Data?, on proxyProtocol: SCNetworkProtocol) -> Bool {
    guard let data else { return SCNetworkProtocolSetConfiguration(proxyProtocol, nil) }
    guard
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil),
      let dictionary = propertyList as? [String: Any]
    else { return false }
    return SCNetworkProtocolSetConfiguration(proxyProtocol, dictionary as CFDictionary)
  }

  private func commitAndApply(_ preferences: SCPreferences) throws {
    guard SCPreferencesCommitChanges(preferences) else {
      throw SystemProxyError.commitFailed(systemConfigurationError())
    }
    guard SCPreferencesApplyChanges(preferences) else {
      throw SystemProxyError.applyFailed(systemConfigurationError())
    }
  }

  private func withPreferences<T>(_ body: (SCPreferences) throws -> T) throws -> T {
    var authorization: AuthorizationRef?
    let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
    let authorizationStatus = AuthorizationCreate(nil, nil, flags, &authorization)
    guard authorizationStatus == errAuthorizationSuccess, let authorization else {
      throw SystemProxyError.authorizationFailed(authorizationStatus)
    }
    defer { AuthorizationFree(authorization, []) }

    guard
      let preferences = SCPreferencesCreateWithAuthorization(
        nil, "ShadowsocksX-NG2" as CFString, nil, authorization)
    else { throw SystemProxyError.preferencesUnavailable }
    return try body(preferences)
  }

  private func systemConfigurationError() -> String {
    String(cString: SCErrorString(SCError()))
  }
}

private func lockPreferencesOrThrow(_ preferences: SCPreferences) throws {
  guard SCPreferencesLock(preferences, true) else {
    throw SystemProxyError.preferencesBusy
  }
}
