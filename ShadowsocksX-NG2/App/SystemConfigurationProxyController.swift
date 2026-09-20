import Foundation
import Security
import SystemConfiguration

/// System proxy write seam. The controller calls it only after endpoint health
/// succeeds; tests replace it without touching the user's network settings.
protocol SystemProxyControlling {
  func apply(_ configuration: SystemProxyConfiguration) throws
  func restore() throws
}

enum SystemProxyError: Error, Equatable {
  case authorizationFailed(Int32)
  case preferencesUnavailable
  case preferencesBusy
  case noCurrentNetworkSet
  case noProxyServices
  case unreadableService(String)
  case ownershipConflict(String)
  case invalidStoredConfiguration(String)
  case cannotWriteService(String)
  case commitFailed(String)
  case applyFailed(String)
  case ownershipStoreFailed(String)

  var presentedReason: String {
    switch self {
    case .authorizationFailed:
      "没有获得修改系统代理所需的授权"
    case .preferencesUnavailable:
      "系统网络配置不可用"
    case .preferencesBusy:
      "系统网络配置正被其他设置操作占用"
    case .noCurrentNetworkSet:
      "没有当前网络位置"
    case .noProxyServices:
      "当前网络位置没有可写入的网络服务"
    case .unreadableService(let serviceID):
      "无法读取网络服务 \(serviceID) 的代理配置"
    case .ownershipConflict(let serviceID):
      "网络服务 \(serviceID) 的代理配置已被其他设置改动，未覆盖"
    case .invalidStoredConfiguration:
      "保存的系统代理配置无效"
    case .cannotWriteService(let serviceID):
      "无法写入网络服务 \(serviceID) 的代理配置"
    case .commitFailed(let detail):
      "系统代理提交失败：\(detail)"
    case .applyFailed(let detail):
      "系统代理应用失败：\(detail)"
    case .ownershipStoreFailed(let detail):
      "系统代理所有权记录失败：\(detail)"
    }
  }
}

/// Writes the Proxies entity of every service in the current network set.
/// Before the first write it snapshots each complete dictionary. Later writes
/// are allowed only while every previously applied dictionary is unchanged;
/// this prevents 2.0 from restoring over a user's manual or MDM change.
final class SystemConfigurationProxyController: SystemProxyControlling {
  private struct ServiceSnapshot {
    let id: String
    let proxyProtocol: SCNetworkProtocol
    let configuration: Data?
  }

  private let ownershipStore: SystemProxyOwnershipStoring

  init(
    ownershipStore: SystemProxyOwnershipStoring = FileSystemSystemProxyOwnershipStore()
  ) {
    self.ownershipStore = ownershipStore
  }

  func apply(_ configuration: SystemProxyConfiguration) throws {
    try withPreferences { preferences in
      let services = try serviceSnapshots(in: preferences)
      guard !services.isEmpty else { throw SystemProxyError.noProxyServices }

      let existing = try loadOwnership()
      let plan = try makePlan(
        services: services, existing: existing, target: configuration.target)

      try SCPreferencesLockOrThrow(preferences)
      defer { SCPreferencesUnlock(preferences) }
      try saveOwnership(plan.ownership)
      do {
        for (service, entry) in zip(services, plan.entries) {
          guard setConfiguration(entry.appliedConfiguration, on: service.proxyProtocol) else {
            throw SystemProxyError.cannotWriteService(service.id)
          }
        }
        try commitAndApply(preferences)
      } catch {
        let rollbackSucceeded = rollback(services, in: preferences)
        try restoreOwnership(existing)
        if !rollbackSucceeded {
          throw SystemProxyError.applyFailed("系统代理变更回滚失败：\(systemConfigurationError())")
        }
        throw error
      }
    }
  }

  private func makePlan(
    services: [ServiceSnapshot],
    existing: SystemProxyOwnershipRecord?,
    target: SystemProxyConfiguration.Target
  ) throws -> (
    entries: [SystemProxyOwnershipRecord.Entry],
    ownership: SystemProxyOwnershipRecord
  ) {
    let existingByID = Dictionary(
      uniqueKeysWithValues: existing?.entries.map { ($0.serviceID, $0) } ?? [])
    var entries: [SystemProxyOwnershipRecord.Entry] = []

    for service in services {
      if let owned = existingByID[service.id] {
        guard
          !hasOwnershipConflict(
            current: service.configuration, applied: owned.appliedConfiguration
          )
        else {
          throw SystemProxyError.ownershipConflict(service.id)
        }
      }
      let original = existingByID[service.id]?.originalConfiguration ?? service.configuration
      let applied = try managedConfiguration(
        basedOn: original, target: target, serviceID: service.id)
      entries.append(
        SystemProxyOwnershipRecord.Entry(
          serviceID: service.id,
          originalConfiguration: original,
          appliedConfiguration: applied))
    }

    var allEntries = Dictionary(
      uniqueKeysWithValues: existing?.entries.map { ($0.serviceID, $0) } ?? [])
    for entry in entries {
      allEntries[entry.serviceID] = entry
    }
    return (
      entries: entries,
      ownership: SystemProxyOwnershipRecord(
        entries: allEntries.values.sorted { $0.serviceID < $1.serviceID })
    )
  }

  func restore() throws {
    guard let ownership = try loadOwnership() else { return }
    try withPreferences { preferences in
      let services = try serviceSnapshots(in: preferences)
      let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
      var servicesToRestore: [(ServiceSnapshot, SystemProxyOwnershipRecord.Entry)] = []

      for entry in ownership.entries {
        guard let service = servicesByID[entry.serviceID] else { continue }
        if equivalent(service.configuration, entry.appliedConfiguration) {
          servicesToRestore.append((service, entry))
        } else if equivalent(service.configuration, entry.originalConfiguration) {
          continue
        } else {
          throw SystemProxyError.ownershipConflict(entry.serviceID)
        }
      }

      if servicesToRestore.isEmpty {
        try clearOwnership()
        return
      }

      try SCPreferencesLockOrThrow(preferences)
      defer { SCPreferencesUnlock(preferences) }
      for (service, entry) in servicesToRestore {
        guard setConfiguration(entry.originalConfiguration, on: service.proxyProtocol) else {
          throw SystemProxyError.cannotWriteService(entry.serviceID)
        }
      }
      try commitAndApply(preferences)
      try clearOwnership()
    }
  }

  private func saveOwnership(_ record: SystemProxyOwnershipRecord) throws {
    do {
      try ownershipStore.save(record)
    } catch {
      throw SystemProxyError.ownershipStoreFailed(String(describing: error))
    }
  }

  private func clearOwnership() throws {
    do {
      try ownershipStore.clear()
    } catch {
      throw SystemProxyError.ownershipStoreFailed(String(describing: error))
    }
  }

  private func restoreOwnership(_ record: SystemProxyOwnershipRecord?) throws {
    if let record {
      try saveOwnership(record)
    } else {
      try clearOwnership()
    }
  }

  private func rollback(
    _ services: [ServiceSnapshot], in preferences: SCPreferences
  ) -> Bool {
    for service in services {
      guard setConfiguration(service.configuration, on: service.proxyProtocol) else {
        return false
      }
    }
    return SCPreferencesCommitChanges(preferences) && SCPreferencesApplyChanges(preferences)
  }

  private func loadOwnership() throws -> SystemProxyOwnershipRecord? {
    do {
      return try ownershipStore.load()
    } catch {
      throw SystemProxyError.ownershipStoreFailed(String(describing: error))
    }
  }

  private func serviceSnapshots(in preferences: SCPreferences) throws -> [ServiceSnapshot] {
    guard let set = SCNetworkSetCopyCurrent(preferences) else {
      throw SystemProxyError.noCurrentNetworkSet
    }
    guard let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
      throw SystemProxyError.noProxyServices
    }

    return try services.compactMap { service in
      guard
        let serviceID = SCNetworkServiceGetServiceID(service) as String?,
        let proxyProtocol = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
      else { return nil }
      return ServiceSnapshot(
        id: serviceID,
        proxyProtocol: proxyProtocol,
        configuration: try propertyListData(from: SCNetworkProtocolGetConfiguration(proxyProtocol)))
    }
  }

  private func managedConfiguration(
    basedOn original: Data?, target: SystemProxyConfiguration.Target, serviceID: String
  ) throws -> Data {
    let originalDictionary = try dictionary(from: original, serviceID: serviceID)
    let dictionary = SystemProxyPropertyList.applying(target, to: originalDictionary)
    return try propertyListData(from: dictionary, serviceID: serviceID)
  }

  private func dictionary(from data: Data?, serviceID: String) throws -> [String: Any] {
    guard let data else { return [:] }
    guard
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil),
      let dictionary = propertyList as? [String: Any]
    else { throw SystemProxyError.invalidStoredConfiguration(serviceID) }
    return dictionary
  }

  private func propertyListData(
    from value: CFPropertyList?, serviceID: String = ""
  ) throws -> Data? {
    guard let value else { return nil }
    guard let dictionary = value as? [String: Any] else {
      throw SystemProxyError.unreadableService(serviceID)
    }
    return try propertyListData(from: dictionary, serviceID: serviceID)
  }

  private func propertyListData(from dictionary: [String: Any], serviceID: String) throws -> Data {
    do {
      return try PropertyListSerialization.data(
        fromPropertyList: dictionary, format: .binary, options: 0)
    } catch {
      throw SystemProxyError.unreadableService(serviceID)
    }
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

  private func equivalent(_ lhs: Data?, _ rhs: Data?) -> Bool {
    guard let lhs, let rhs else { return lhs == nil && rhs == nil }
    guard
      let left = try? PropertyListSerialization.propertyList(from: lhs, options: [], format: nil)
        as? NSDictionary,
      let right = try? PropertyListSerialization.propertyList(from: rhs, options: [], format: nil)
        as? NSDictionary
    else { return lhs == rhs }
    return left.isEqual(right)
  }

  private func hasOwnershipConflict(current: Data?, applied: Data?) -> Bool {
    !equivalent(current, applied)
  }

  private func commitAndApply(_ preferences: SCPreferences) throws {
    guard SCPreferencesCommitChanges(preferences) else {
      throw SystemProxyError.commitFailed(systemConfigurationError())
    }
    guard SCPreferencesApplyChanges(preferences) else {
      throw SystemProxyError.applyFailed(systemConfigurationError())
    }
  }

  private func withPreferences(_ body: (SCPreferences) throws -> Void) throws {
    var authorization: AuthorizationRef?
    let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
    let authorizationStatus = AuthorizationCreate(nil, nil, flags, &authorization)
    guard authorizationStatus == errAuthorizationSuccess, let authorization else {
      throw SystemProxyError.authorizationFailed(authorizationStatus)
    }
    defer { AuthorizationFree(authorization, []) }

    guard
      let preferences = SCPreferencesCreateWithAuthorization(
        nil, "ShadowsocksX-NG" as CFString, nil, authorization)
    else { throw SystemProxyError.preferencesUnavailable }
    try body(preferences)
  }

  private func systemConfigurationError() -> String {
    String(cString: SCErrorString(SCError()))
  }
}

private func SCPreferencesLockOrThrow(_ preferences: SCPreferences) throws {
  guard SCPreferencesLock(preferences, true) else {
    throw SystemProxyError.preferencesBusy
  }
}
