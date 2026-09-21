import Foundation
import Security
import SystemConfiguration

/// Legacy 写入的系统代理清理（issue #37）：读取当前网络位置每个服务的
/// Proxies 字典并按 Legacy 特征值判定归属，只改写判定为 Legacy 的服务
/// （禁用全部代理面、移除端点值）；空配置跳过；未知所有者原样保留并点名
/// 返回，绝不覆盖。事务纪律与 SystemConfigurationProxyController 一致：
/// 写入失败回滚到本次操作前状态。实现只抛 LegacyHandoffError.proxyCleanFailed。
final class SystemConfigurationLegacyProxyCleaner: LegacyProxyCleaning {
  private struct ServiceSnapshot {
    let id: String
    let proxyProtocol: SCNetworkProtocol
    let configuration: Data?
  }

  func cleanLegacyOwnedProxy(ports: LegacyListenPorts) throws -> LegacyProxyCleanOutcome {
    do {
      return try withPreferences { preferences in
        let (legacyServices, unknownOwnerServiceIDs) =
          try classifyServices(in: preferences, ports: ports)
        guard !legacyServices.isEmpty else {
          return LegacyProxyCleanOutcome(
            cleanedServiceIDs: [], unknownOwnerServiceIDs: unknownOwnerServiceIDs)
        }
        let cleanedServiceIDs = try clean(legacyServices, in: preferences)
        return LegacyProxyCleanOutcome(
          cleanedServiceIDs: cleanedServiceIDs,
          unknownOwnerServiceIDs: unknownOwnerServiceIDs)
      }
    } catch let error as LegacyHandoffError {
      throw error
    } catch {
      throw LegacyHandoffError.proxyCleanFailed(detail: describe(error))
    }
  }

  // MARK: - SystemConfiguration 管道（与 SystemConfigurationProxyController 同纪律）

  /// 归属分类（只读）：Legacy 服务捕获原字典供清理投影；未知所有者点名返回。
  private func classifyServices(
    in preferences: SCPreferences, ports: LegacyListenPorts
  ) throws -> (
    legacy: [(ServiceSnapshot, [String: Any])], unknownOwnerIDs: [String]
  ) {
    let services = try serviceSnapshots(in: preferences)
    guard !services.isEmpty else {
      throw LegacyHandoffError.proxyCleanFailed(
        detail: SystemProxyError.noProxyServices.presentedReason)
    }
    var legacyServices: [(ServiceSnapshot, [String: Any])] = []
    var unknownOwnerIDs: [String] = []
    for service in services {
      let dictionary = try readableDictionary(
        from: service.configuration, serviceID: service.id)
      switch LegacySystemProxySignature.classify(dictionary, ports: ports) {
      case .none:
        continue
      case .legacy:
        legacyServices.append((service, dictionary))
      case .other:
        unknownOwnerIDs.append(service.id)
      }
    }
    return (legacyServices, unknownOwnerIDs)
  }

  /// 写入并提交；失败回滚到本次操作前状态。
  private func clean(
    _ legacyServices: [(ServiceSnapshot, [String: Any])], in preferences: SCPreferences
  ) throws -> [String] {
    try SCPreferencesLockOrThrow(preferences)
    defer { SCPreferencesUnlock(preferences) }
    do {
      for (service, dictionary) in legacyServices {
        let cleaned = LegacySystemProxySignature.cleaned(dictionary)
        guard SCNetworkProtocolSetConfiguration(service.proxyProtocol, cleaned as CFDictionary)
        else {
          throw LegacyHandoffError.proxyCleanFailed(
            detail: SystemProxyError.cannotWriteService(service.id).presentedReason)
        }
      }
      try commitAndApply(preferences)
    } catch {
      let rollbackSucceeded = rollback(legacyServices, in: preferences)
      var detail = describe(error)
      if !rollbackSucceeded {
        detail += "；系统代理变更回滚失败：\(systemConfigurationError())"
      }
      throw LegacyHandoffError.proxyCleanFailed(detail: detail)
    }
    return legacyServices.map { $0.0.id }
  }

  private func withPreferences(
    _ body: (SCPreferences) throws -> LegacyProxyCleanOutcome
  ) throws -> LegacyProxyCleanOutcome {
    var authorization: AuthorizationRef?
    let flags: AuthorizationFlags = [.interactionAllowed, .extendRights, .preAuthorize]
    let authorizationStatus = AuthorizationCreate(nil, nil, flags, &authorization)
    guard authorizationStatus == errAuthorizationSuccess, let authorization else {
      throw LegacyHandoffError.proxyCleanFailed(
        detail: SystemProxyError.authorizationFailed(authorizationStatus).presentedReason)
    }
    defer { AuthorizationFree(authorization, []) }

    guard
      let preferences = SCPreferencesCreateWithAuthorization(
        nil, "ShadowsocksX-NG" as CFString, nil, authorization)
    else {
      throw LegacyHandoffError.proxyCleanFailed(
        detail: SystemProxyError.preferencesUnavailable.presentedReason)
    }
    return try body(preferences)
  }

  private func serviceSnapshots(in preferences: SCPreferences) throws -> [ServiceSnapshot] {
    guard let set = SCNetworkSetCopyCurrent(preferences) else {
      throw LegacyHandoffError.proxyCleanFailed(
        detail: SystemProxyError.noCurrentNetworkSet.presentedReason)
    }
    guard let services = SCNetworkSetCopyServices(set) as? [SCNetworkService] else {
      throw LegacyHandoffError.proxyCleanFailed(
        detail: SystemProxyError.noProxyServices.presentedReason)
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
          from: SCNetworkProtocolGetConfiguration(proxyProtocol), serviceID: serviceID))
    }
  }

  private func rollback(
    _ services: [(ServiceSnapshot, [String: Any])], in preferences: SCPreferences
  ) -> Bool {
    for (service, original) in services {
      guard SCNetworkProtocolSetConfiguration(service.proxyProtocol, original as CFDictionary)
      else {
        return false
      }
    }
    return SCPreferencesCommitChanges(preferences) && SCPreferencesApplyChanges(preferences)
  }

  private func readableDictionary(
    from data: Data?, serviceID: String
  ) throws -> [String: Any] {
    guard let data else { return [:] }
    guard
      let propertyList = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil),
      let dictionary = propertyList as? [String: Any]
    else {
      throw LegacyHandoffError.proxyCleanFailed(
        detail: SystemProxyError.invalidStoredConfiguration(serviceID).presentedReason)
    }
    return dictionary
  }

  private func propertyListData(
    from value: CFPropertyList?, serviceID: String
  ) throws -> Data? {
    guard let value else { return nil }
    guard let dictionary = value as? [String: Any] else {
      throw LegacyHandoffError.proxyCleanFailed(
        detail: SystemProxyError.unreadableService(serviceID).presentedReason)
    }
    return try PropertyListSerialization.data(
      fromPropertyList: dictionary, format: .binary, options: 0)
  }

  private func commitAndApply(_ preferences: SCPreferences) throws {
    guard SCPreferencesCommitChanges(preferences) else {
      throw LegacyHandoffError.proxyCleanFailed(
        detail: "提交失败：\(systemConfigurationError())")
    }
    guard SCPreferencesApplyChanges(preferences) else {
      throw LegacyHandoffError.proxyCleanFailed(
        detail: "应用失败：\(systemConfigurationError())")
    }
  }

  private func describe(_ error: Error) -> String {
    (error as? SystemProxyError)?.presentedReason ?? String(describing: error)
  }

  private func systemConfigurationError() -> String {
    String(cString: SCErrorString(SCError()))
  }
}

private func SCPreferencesLockOrThrow(_ preferences: SCPreferences) throws {
  guard SCPreferencesLock(preferences, true) else {
    throw LegacyHandoffError.proxyCleanFailed(
      detail: SystemProxyError.preferencesBusy.presentedReason)
  }
}
