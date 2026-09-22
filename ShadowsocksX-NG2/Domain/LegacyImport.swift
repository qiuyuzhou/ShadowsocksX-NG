import Darwin
import Foundation

/// One server record as it appeared in the Legacy `ServerProfiles` array.
/// Optional fields are intentional: malformed records are reported and skipped
/// by the planner instead of being force-cast like the historical app did.
struct LegacyServerSnapshot: Equatable, Sendable {
  let index: Int
  let isDictionary: Bool
  let id: String?
  let address: String?
  let port: Int?
  let method: String?
  let password: String?
  let remark: String?
  let plugin: String?
  let pluginOptions: String?
}

/// Read-only snapshot of the persisted Legacy server records. Legacy
/// preferences are deliberately not part of the import projection.
struct LegacySnapshot: Equatable, Sendable {
  let profiles: [LegacyServerSnapshot]
  let hasServerRecords: Bool

  init(propertyList: [String: Any]) throws {
    if let rawProfiles = propertyList["ServerProfiles"] {
      guard let profileValues = rawProfiles as? [Any] else {
        throw LegacyImportError.malformedSnapshot("ServerProfiles 不是数组")
      }
      profiles = profileValues.enumerated().map { index, rawValue in
        Self.profileSnapshot(index: index, rawValue: rawValue)
      }
    } else {
      profiles = []
    }
    // An empty or preference-only Legacy domain is not an importable
    // snapshot, so first launch does not offer a misleading empty migration.
    hasServerRecords = !profiles.isEmpty
  }
}

extension LegacySnapshot {
  private static func profileSnapshot(index: Int, rawValue: Any) -> LegacyServerSnapshot {
    guard let values = rawValue as? [String: Any] else {
      return LegacyServerSnapshot(
        index: index, isDictionary: false, id: nil, address: nil, port: nil,
        method: nil, password: nil, remark: nil, plugin: nil, pluginOptions: nil)
    }
    return LegacyServerSnapshot(
      index: index,
      isDictionary: true,
      id: stringValue(values["Id"]),
      address: stringValue(values["ServerHost"]),
      port: intValue(values["ServerPort"]),
      method: stringValue(values["Method"]),
      password: stringValue(values["Password"]),
      remark: stringValue(values["Remark"]),
      plugin: stringValue(values["Plugin"]),
      pluginOptions: stringValue(values["PluginOptions"])
    )
  }

  private static func stringValue(_ value: Any?) -> String? {
    value as? String
  }

  private static func intValue(_ value: Any?) -> Int? {
    guard let value = value as? NSNumber else { return nil }
    return value.intValue
  }
}

/// Source seam for discovery and fixture injection.
protocol LegacySnapshotProviding {
  func readSnapshot() throws -> LegacySnapshot?
}

/// Reads only the persisted application domain, not registered defaults. This
/// prevents a fresh 2.0 process from mistaking registered Legacy defaults for a
/// user-owned Legacy installation.
struct UserDefaultsLegacySnapshotProvider: LegacySnapshotProviding {
  static let legacyBundleIdentifier = "com.qiuyuzhou.ShadowsocksX-NG"

  let defaults: UserDefaults
  let bundleIdentifier: String

  init(
    defaults: UserDefaults = .standard,
    bundleIdentifier: String = Self.legacyBundleIdentifier
  ) {
    self.defaults = defaults
    self.bundleIdentifier = bundleIdentifier
  }

  func readSnapshot() throws -> LegacySnapshot? {
    let values = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
    let snapshot = try LegacySnapshot(propertyList: values)
    return snapshot.hasServerRecords ? snapshot : nil
  }
}

/// Completion marker seam. `false` removes the marker rather than persisting a
/// false value, preserving the distinction between "skipped" and "completed".
protocol LegacyImportMarkerStoring {
  func isCompleted() throws -> Bool
  func setCompleted(_ completed: Bool) throws
}

struct UserDefaultsLegacyImportMarkerStore: LegacyImportMarkerStoring {
  static let key = "legacyImport.completed"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func isCompleted() throws -> Bool {
    defaults.bool(forKey: Self.key)
  }

  func setCompleted(_ completed: Bool) throws {
    if completed {
      defaults.set(true, forKey: Self.key)
    } else {
      defaults.removeObject(forKey: Self.key)
    }
  }
}

protocol LegacyCatalogStoring {
  func load() throws -> CatalogDocument
  func save(_ document: CatalogDocument) throws
}

extension CatalogFileStore: LegacyCatalogStoring {}

struct LegacySkippedRecord: Equatable, Sendable {
  let index: Int
  let description: String
  let reason: String
}

struct LegacyImportReport: Equatable, Sendable {
  let groupName: String
  let importedServerCount: Int
  let skippedRecords: [LegacySkippedRecord]
  let regeneratedIdentityCount: Int
}

struct LegacyImportOutcome: Equatable, Sendable {
  let groupID: NodeID
  let report: LegacyImportReport
}

enum LegacyImportError: Error, Equatable {
  case noSnapshot
  case alreadyCompleted
  case malformedSnapshot(String)
  case commitFailed(detail: String)

  var presentedReason: String {
    switch self {
    case .noSnapshot:
      return "没有发现可导入的 Legacy 配置"
    case .alreadyCompleted:
      return "Legacy 配置已经导入；如需再次导入，请明确选择再次导入"
    case .malformedSnapshot(let detail):
      return "Legacy 快照无效：\(detail)"
    case .commitFailed(let detail):
      return "Legacy 导入未完成，已回滚 2.0 写入：\(detail)"
    }
  }
}

struct LegacyImportPlan {
  let groupID: NodeID
  let document: CatalogDocument
  let credentials: [CredentialReference: String]
  let report: LegacyImportReport
}

/// Pure planning seam: translates one immutable Legacy snapshot into a new
/// manual subtree and credential references. No preferences or active target
/// state enter the plan.
struct LegacyImportPlanner {
  static func makePlan(
    snapshot: LegacySnapshot,
    existingDocument: CatalogDocument
  ) throws -> LegacyImportPlan {
    var catalog = existingDocument.catalog
    let groupName = nextGroupName(in: catalog)
    let groupID = try catalog.addGroup(groupName)
    let serverImport = try importServers(snapshot.profiles, into: &catalog, groupID: groupID)
    let report = LegacyImportReport(
      groupName: groupName,
      importedServerCount: serverImport.importedServerCount,
      skippedRecords: serverImport.skippedRecords,
      regeneratedIdentityCount: serverImport.regeneratedIdentityCount)
    return LegacyImportPlan(
      groupID: groupID,
      document: CatalogDocument(catalog: catalog, subscriptions: existingDocument.subscriptions),
      credentials: serverImport.credentials,
      report: report)
  }
}

extension LegacyImportPlanner {
  private struct ServerImportResult {
    let credentials: [CredentialReference: String]
    let skippedRecords: [LegacySkippedRecord]
    let regeneratedIdentityCount: Int
    let importedServerCount: Int
  }

  private static func importServers(
    _ profiles: [LegacyServerSnapshot],
    into catalog: inout ConfigurationCatalog,
    groupID: NodeID
  ) throws -> ServerImportResult {
    var credentials: [CredentialReference: String] = [:]
    var skippedRecords: [LegacySkippedRecord] = []
    var regeneratedIdentityCount = 0
    var importedServerCount = 0
    var usedLegacyIDs: [String: Int] = [:]

    for profile in profiles {
      if let id = profile.id { usedLegacyIDs[legacyIdentityKey(id), default: 0] += 1 }
    }

    for profile in profiles {
      guard profile.isDictionary else {
        skippedRecords.append(
          LegacySkippedRecord(
            index: profile.index, description: "第 \(profile.index + 1) 条记录", reason: "记录不是字典"))
        continue
      }
      guard let address = profile.address?.trimmingCharacters(in: .whitespacesAndNewlines),
        !address.isEmpty, isValidHost(address)
      else {
        skippedRecords.append(
          LegacySkippedRecord(
            index: profile.index, description: profile.address ?? "第 \(profile.index + 1) 条记录",
            reason: "服务器地址缺失或无效"))
        continue
      }
      guard let port = profile.port, (1...65_535).contains(port) else {
        skippedRecords.append(
          LegacySkippedRecord(
            index: profile.index, description: address, reason: "服务器端口缺失或无效"))
        continue
      }
      guard let method = profile.method?.trimmingCharacters(in: .whitespacesAndNewlines),
        !method.isEmpty
      else {
        skippedRecords.append(
          LegacySkippedRecord(
            index: profile.index, description: address, reason: "加密方式缺失或无效"))
        continue
      }
      guard let password = profile.password, !password.isEmpty else {
        skippedRecords.append(
          LegacySkippedRecord(
            index: profile.index, description: address, reason: "密码缺失或为空"))
        continue
      }

      let nodeID: NodeID
      if let rawID = profile.id,
        UUID(uuidString: rawID) != nil,
        usedLegacyIDs[legacyIdentityKey(rawID)] == 1,
        !containsEquivalentNodeID(rawID, in: catalog)
      {
        nodeID = NodeID(rawValue: rawID)
      } else {
        nodeID = .fresh()
        regeneratedIdentityCount += 1
      }

      let passwordRef = CredentialReference.fresh()
      credentials[passwordRef] = password
      let plugin = profile.plugin?.isEmpty == false ? profile.plugin : nil
      let pluginOptionsRef: CredentialReference?
      if let pluginOptions = profile.pluginOptions, !pluginOptions.isEmpty {
        let reference = CredentialReference.fresh()
        credentials[reference] = pluginOptions
        pluginOptionsRef = reference
      } else {
        pluginOptionsRef = nil
      }
      let fields = ServerFields(
        address: address,
        port: port,
        encryptionMethod: method,
        passwordRef: passwordRef,
        remark: profile.remark ?? "",
        pluginProgram: plugin,
        pluginOptionsRef: pluginOptionsRef)
      try catalog.addServer(fields, id: nodeID, to: groupID)
      importedServerCount += 1
    }

    return ServerImportResult(
      credentials: credentials,
      skippedRecords: skippedRecords,
      regeneratedIdentityCount: regeneratedIdentityCount,
      importedServerCount: importedServerCount)
  }

  private static func legacyIdentityKey(_ rawID: String) -> String {
    UUID(uuidString: rawID)?.uuidString.lowercased() ?? rawID
  }

  private static func containsEquivalentNodeID(
    _ rawID: String,
    in catalog: ConfigurationCatalog
  ) -> Bool {
    let identityKey = legacyIdentityKey(rawID)
    return catalog.entries.keys.contains { existingID in
      existingID.rawValue == rawID || legacyIdentityKey(existingID.rawValue) == identityKey
    }
  }

  private static func nextGroupName(in catalog: ConfigurationCatalog) -> String {
    let base = "Legacy 导入"
    let names = Set(
      catalog.entries.values.compactMap { entry -> String? in
        guard case .group(let fields) = entry.kind else { return nil }
        return fields.name
      })
    guard names.contains(base) else { return base }
    var suffix = 2
    while names.contains("\(base) \(suffix)") { suffix += 1 }
    return "\(base) \(suffix)"
  }

  private static func isValidHost(_ value: String) -> Bool {
    var ipv4 = in_addr()
    if value.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 { return true }
    var ipv6 = in6_addr()
    if value.withCString({ inet_pton(AF_INET6, $0, &ipv6) }) == 1 { return true }
    let pattern =
      "^(([a-zA-Z0-9]|[a-zA-Z0-9][a-zA-Z0-9\\-]*[a-zA-Z0-9])\\.)*([A-Za-z0-9]|[A-Za-z0-9][a-zA-Z0-9\\-]*[A-Za-z0-9])$"
    return value.range(of: pattern, options: .regularExpression) != nil
  }
}

/// Coordinates the pure plan with the catalog, credential store, and import
/// completion marker. Preferences and activation state are intentionally absent
/// from this transaction.
final class LegacyImportService {
  private let source: LegacySnapshotProviding
  private let catalogStore: LegacyCatalogStoring
  private let credentials: CredentialStoring
  private let marker: LegacyImportMarkerStoring

  init(
    source: LegacySnapshotProviding = UserDefaultsLegacySnapshotProvider(),
    catalogStore: LegacyCatalogStoring = CatalogFileStore(
      fileURL: CatalogFileStore.defaultFileURL()),
    credentials: CredentialStoring = KeychainCredentialStore(),
    marker: LegacyImportMarkerStoring = UserDefaultsLegacyImportMarkerStore()
  ) {
    self.source = source
    self.catalogStore = catalogStore
    self.credentials = credentials
    self.marker = marker
  }

  func readSnapshot() throws -> LegacySnapshot? {
    try source.readSnapshot()
  }

  func isCompleted() throws -> Bool {
    try marker.isCompleted()
  }

  func importCurrentSnapshot(reimport: Bool = false) throws -> LegacyImportOutcome {
    guard let snapshot = try source.readSnapshot() else {
      throw LegacyImportError.noSnapshot
    }
    return try importSnapshot(snapshot, reimport: reimport)
  }

  func importSnapshot(_ snapshot: LegacySnapshot, reimport: Bool = false)
    throws -> LegacyImportOutcome
  {
    let wasCompleted = try marker.isCompleted()
    guard !wasCompleted || reimport else {
      throw LegacyImportError.alreadyCompleted
    }

    let originalDocument = try catalogStore.load()
    let plan = try LegacyImportPlanner.makePlan(
      snapshot: snapshot, existingDocument: originalDocument)
    let touchedReferences = Set(plan.credentials.keys)
    var originalSecrets: [CredentialReference: String?] = [:]
    for reference in touchedReferences {
      originalSecrets[reference] = try credentials.secret(for: reference)
    }

    do {
      for (reference, secret) in plan.credentials {
        try credentials.save(secret, for: reference)
      }
      try catalogStore.save(plan.document)
      try marker.setCompleted(true)
    } catch {
      let rollbackFailures = rollback(
        originalDocument: originalDocument,
        wasCompleted: wasCompleted,
        originalSecrets: originalSecrets)
      let details = [
        "提交：\(error)",
        rollbackFailures.isEmpty ? nil : "回滚：" + rollbackFailures.joined(separator: "；"),
      ].compactMap { $0 }.joined(separator: "；")
      throw LegacyImportError.commitFailed(detail: details)
    }

    return LegacyImportOutcome(
      groupID: plan.groupID,
      report: plan.report)
  }
}

extension LegacyImportService {
  fileprivate func rollback(
    originalDocument: CatalogDocument,
    wasCompleted: Bool,
    originalSecrets: [CredentialReference: String?]
  ) -> [String] {
    var failures: [String] = []
    do {
      try marker.setCompleted(wasCompleted)
    } catch {
      failures.append("完成标记：\(error)")
    }
    do {
      try catalogStore.save(originalDocument)
    } catch {
      failures.append("目录：\(error)")
    }
    for (reference, secret) in originalSecrets {
      do {
        if let secret {
          try credentials.save(secret, for: reference)
        } else {
          try credentials.delete(reference)
        }
      } catch {
        failures.append("凭据 \(reference.rawValue)：\(error)")
      }
    }
    return failures
  }
}
