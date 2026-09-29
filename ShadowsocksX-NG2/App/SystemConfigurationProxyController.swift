import Foundation
import Security
import SystemConfiguration

/// System proxy write seam. The controller calls it only after endpoint health
/// succeeds; tests replace it without touching the user's network settings.
/// `apply` 返回 written / unchanged：值语义等价时零写入零授权（issue #70）。
protocol SystemProxyControlling {
  @discardableResult
  func apply(_ configuration: SystemProxyConfiguration) throws -> SystemProxyWriteOutcome
  func restore() throws
}

/// Writes the Proxies entity of every service in the current network set.
/// Before the first write it snapshots each complete dictionary. Later writes
/// are allowed only while every previously applied dictionary is unchanged;
/// this prevents 2.0 from restoring over a user's manual or MDM change.
/// 期望值与当前值语义等价的 service 不写入；全部等价时不加锁、不提交，
/// 授权弹窗只发生在存在真实值变更的提交上（issue #70）。
final class SystemConfigurationProxyController: SystemProxyControlling {
  private struct ServiceSnapshot {
    let id: String
    let proxyProtocol: SCNetworkProtocol
    let configuration: Data?

    var plannerState: SystemProxyServiceState {
      SystemProxyServiceState(serviceID: id, configuration: configuration)
    }
  }

  private let ownershipStore: SystemProxyOwnershipStoring

  init(
    ownershipStore: SystemProxyOwnershipStoring = FileSystemSystemProxyOwnershipStore()
  ) {
    self.ownershipStore = ownershipStore
  }

  func apply(_ configuration: SystemProxyConfiguration) throws -> SystemProxyWriteOutcome {
    try withPreferences { preferences in
      let services = try serviceSnapshots(in: preferences)
      guard !services.isEmpty else { throw SystemProxyError.noProxyServices }

      let existing = try loadOwnership()
      let plan = try SystemProxyPlanner.makePlan(
        services: services.map(\.plannerState),
        existing: existing,
        configuration: configuration)
      guard !plan.writes.isEmpty else {
        // 期望值与系统当前值语义等价：零写入、零授权。adopt 发生时仍需刷新
        // ownership record（本地文件写入，无需授权）。
        if plan.ownershipChanged { try saveOwnership(plan.ownership) }
        return .unchanged
      }

      let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
      try SCPreferencesLockOrThrow(preferences)
      defer { SCPreferencesUnlock(preferences) }
      try saveOwnership(plan.ownership)
      do {
        for entry in plan.writes {
          guard let service = servicesByID[entry.serviceID],
            setConfiguration(entry.appliedConfiguration, on: service.proxyProtocol)
          else { throw SystemProxyError.cannotWriteService(entry.serviceID) }
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
      return .written
    }
  }

  func restore() throws {
    guard let ownership = try loadOwnership() else { return }
    try withPreferences { preferences in
      let services = try serviceSnapshots(in: preferences)
      let servicesByID = Dictionary(uniqueKeysWithValues: services.map { ($0.id, $0) })
      var servicesToRestore: [(ServiceSnapshot, SystemProxyOwnershipRecord.Entry)] = []

      for entry in ownership.entries {
        guard let service = servicesByID[entry.serviceID] else { continue }
        if SystemProxyPlanner.equivalent(service.configuration, entry.appliedConfiguration) {
          servicesToRestore.append((service, entry))
        } else if SystemProxyPlanner.equivalent(
          service.configuration, entry.originalConfiguration)
        {
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
        configuration: try propertyListData(
          from: SCNetworkProtocolGetConfiguration(proxyProtocol)))
    }
  }

  private func propertyListData(
    from value: CFPropertyList?, serviceID: String = ""
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

private func SCPreferencesLockOrThrow(_ preferences: SCPreferences) throws {
  guard SCPreferencesLock(preferences, true) else {
    throw SystemProxyError.preferencesBusy
  }
}
