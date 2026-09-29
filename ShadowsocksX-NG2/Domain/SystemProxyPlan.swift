import Foundation

/// 系统代理写入操作的封闭错误族；planner 与 SC 写入层共用。
enum SystemProxyError: Error, Equatable, Sendable {
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
}

/// 一次系统代理应用决策的逐 service 输入快照（纯值，不含 SystemConfiguration
/// 句柄）：planner 只看字典数据，写入句柄由 App 层持有。
struct SystemProxyServiceState: Equatable, Sendable {
  let serviceID: String
  /// 当前完整的 Proxies 字典；nil 表示该 service 尚无代理配置。
  let configuration: Data?
}

/// 系统代理应用结果：written = 至少写入一个 service（需要一次授权）；
/// unchanged = 期望字典与系统当前值语义等价，零写入、零授权（issue #70）。
enum SystemProxyWriteOutcome: Equatable, Sendable {
  case written
  case unchanged
}

/// 纯决策核心（issue #70）：逐 service 比较期望的 per-service Proxies 字典与
/// 系统当前字典，语义等价的服务零写入。全等时调用方不得加锁、不得提交，
/// 从根上避免无意义的授权弹窗。外部改动恰好等于期望值时按 adopt 语义刷新
/// ownership（original 保留），不报 ownershipConflict。
enum SystemProxyPlanner {
  struct Plan: Equatable, Sendable {
    /// 需要写入的 service 条目；空 = 零写入。
    let writes: [SystemProxyOwnershipRecord.Entry]
    /// 应用后的完整 ownership record（含 adopt 刷新与新增接管）。
    let ownership: SystemProxyOwnershipRecord
    /// record 相对输入是否变化（adopt 或新增接管时为 true）。
    let ownershipChanged: Bool

    var outcome: SystemProxyWriteOutcome {
      writes.isEmpty ? .unchanged : .written
    }
  }

  static func makePlan(
    services: [SystemProxyServiceState],
    existing: SystemProxyOwnershipRecord?,
    configuration: SystemProxyConfiguration
  ) throws -> Plan {
    let existingByID = Dictionary(
      uniqueKeysWithValues: (existing?.entries ?? []).map { ($0.serviceID, $0) })
    var writes: [SystemProxyOwnershipRecord.Entry] = []
    var recordByID = existingByID

    for service in services {
      let owned = existingByID[service.serviceID]
      // 已接管服务严格保留记录中的 original（nil = 接管前无代理配置，二次
      // 变更后 restore 才能清回无配置态）；未接管服务记当前值快照。
      let original: Data?
      if let owned {
        original = owned.originalConfiguration
      } else {
        original = service.configuration
      }
      let desired = try propertyListData(
        from: managedDictionary(
          basedOn: original, configuration: configuration, serviceID: service.serviceID),
        serviceID: service.serviceID)
      if let owned {
        if !equivalent(service.configuration, owned.appliedConfiguration) {
          // 外部改动：恰好等于期望值 → adopt；否则冲突（绝不覆盖）。
          guard equivalent(service.configuration, desired) else {
            throw SystemProxyError.ownershipConflict(service.serviceID)
          }
          recordByID[service.serviceID] = SystemProxyOwnershipRecord.Entry(
            serviceID: service.serviceID,
            originalConfiguration: owned.originalConfiguration,
            appliedConfiguration: desired)
          continue
        }
        if equivalent(service.configuration, desired) {
          continue
        }
      } else if equivalent(service.configuration, desired) {
        // 未接管但系统值已等于期望（如用户手动配过相同端点）：adopt 免授权。
        recordByID[service.serviceID] = SystemProxyOwnershipRecord.Entry(
          serviceID: service.serviceID,
          originalConfiguration: service.configuration,
          appliedConfiguration: desired)
        continue
      }
      let entry = SystemProxyOwnershipRecord.Entry(
        serviceID: service.serviceID,
        originalConfiguration: original,
        appliedConfiguration: desired)
      recordByID[service.serviceID] = entry
      writes.append(entry)
    }

    let ownership = SystemProxyOwnershipRecord(
      entries: recordByID.values.sorted { $0.serviceID < $1.serviceID })
    return Plan(
      writes: writes,
      ownership: ownership,
      ownershipChanged: ownership != existing)
  }

  // MARK: - 语义比较与字典投影（SC 写入层共用）

  /// 属性列表语义等价（键序无关），nil 仅与 nil 等价。
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

  /// 期望字典 = 托管投影应用到 original（保留原字典中的未知附加键）。
  static func managedDictionary(
    basedOn original: Data?, configuration: SystemProxyConfiguration, serviceID: String
  ) throws -> [String: Any] {
    let originalDictionary = try dictionary(from: original, serviceID: serviceID)
    return SystemProxyPropertyList.applying(configuration, to: originalDictionary)
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
