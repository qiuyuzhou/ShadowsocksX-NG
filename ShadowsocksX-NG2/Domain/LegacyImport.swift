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

/// The historical switch-mode preferences were four independent booleans.
/// Optional values distinguish an explicitly persisted value from a registered
/// Legacy default, which is important for migration and re-import semantics.
struct LegacyModeAvailability: Equatable, Sendable {
  var pac: Bool?
  var global: Bool?
  var manual: Bool?
  var externalPAC: Bool?

  var hasPersistedValue: Bool {
    pac != nil || global != nil || manual != nil || externalPAC != nil
  }
}

/// Read-only snapshot of the persisted Legacy UserDefaults domain plus the
/// optional PAC user-rule file. It contains no live UserDefaults object and is
/// therefore safe to use as a deterministic import fixture.
struct LegacySnapshot: Equatable, Sendable {
  static let evidenceKeys: Set<String> = [
    "ServerProfiles",
    "ActiveServerProfileId",
    "LocalSocks5.ListenPort",
    "LocalSocks5.ListenAddress",
    "PacServer.BindToLocalhost",
    "PacServer.ListenPort",
    "LocalSocks5.Timeout",
    "LocalSocks5.EnableUDPRelay",
    "LocalSocks5.EnableVerboseMode",
    "GFWListURL",
    "LocalHTTP.ListenAddress",
    "LocalHTTP.ListenPort",
    "LocalHTTPOn",
    "ProxyExceptions",
    "ExternalPACURL",
    "ShadowsocksRunningMode",
    "EnableSwitchMode.PAC",
    "EnableSwitchMode.Global",
    "EnableSwitchMode.Manual",
    "EnableSwitchMode.ExternalPAC",
    "LaunchAtLogin",
  ]

  let profiles: [LegacyServerSnapshot]
  let activeProfileID: String?
  let socksPort: Int?
  let socksAddress: String?
  let pacBindsToLocalhost: Bool?
  let pacPort: Int?
  let timeoutSeconds: Int?
  let udpRelayEnabled: Bool?
  let verboseLogging: Bool?
  let gfwListURL: String?
  let httpAddress: String?
  let httpPort: Int?
  let httpEnabled: Bool?
  let proxyExceptions: String?
  let externalPACURL: String?
  let runningMode: String?
  let modeAvailability: LegacyModeAvailability
  let loginAtLogin: Bool?
  let pacUserRules: String?
  let hasPersistedEvidence: Bool

  init(propertyList: [String: Any], userRules: String?) throws {
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

    activeProfileID = Self.stringValue(propertyList["ActiveServerProfileId"])
    socksPort = Self.intValue(propertyList["LocalSocks5.ListenPort"])
    socksAddress = Self.stringValue(propertyList["LocalSocks5.ListenAddress"])
    pacBindsToLocalhost = Self.boolValue(propertyList["PacServer.BindToLocalhost"])
    pacPort = Self.intValue(propertyList["PacServer.ListenPort"])
    timeoutSeconds = Self.intValue(propertyList["LocalSocks5.Timeout"])
    udpRelayEnabled = Self.boolValue(propertyList["LocalSocks5.EnableUDPRelay"])
    verboseLogging = Self.boolValue(propertyList["LocalSocks5.EnableVerboseMode"])
    gfwListURL = Self.stringValue(propertyList["GFWListURL"])
    httpAddress = Self.stringValue(propertyList["LocalHTTP.ListenAddress"])
    httpPort = Self.intValue(propertyList["LocalHTTP.ListenPort"])
    httpEnabled = Self.boolValue(propertyList["LocalHTTPOn"])
    proxyExceptions = Self.stringValue(propertyList["ProxyExceptions"])
    externalPACURL = Self.stringValue(propertyList["ExternalPACURL"])
    runningMode = Self.stringValue(propertyList["ShadowsocksRunningMode"])
    modeAvailability = LegacyModeAvailability(
      pac: Self.boolValue(propertyList["EnableSwitchMode.PAC"]),
      global: Self.boolValue(propertyList["EnableSwitchMode.Global"]),
      manual: Self.boolValue(propertyList["EnableSwitchMode.Manual"]),
      externalPAC: Self.boolValue(propertyList["EnableSwitchMode.ExternalPAC"])
    )
    loginAtLogin = Self.boolValue(propertyList["LaunchAtLogin"])
    pacUserRules = userRules
    hasPersistedEvidence =
      !propertyList.keys.filter(Self.evidenceKeys.contains).isEmpty
      || userRules != nil
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

  private static func boolValue(_ value: Any?) -> Bool? {
    guard let value = value as? NSNumber else { return nil }
    return value.boolValue
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
  static let defaultUserRulesURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent(".ShadowsocksX-NG/user-rule.txt")

  let defaults: UserDefaults
  let bundleIdentifier: String
  let userRulesURL: URL

  init(
    defaults: UserDefaults = .standard,
    bundleIdentifier: String = Self.legacyBundleIdentifier,
    userRulesURL: URL = Self.defaultUserRulesURL
  ) {
    self.defaults = defaults
    self.bundleIdentifier = bundleIdentifier
    self.userRulesURL = userRulesURL
  }

  func readSnapshot() throws -> LegacySnapshot? {
    let values = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
    var userRules: String?
    if FileManager.default.fileExists(atPath: userRulesURL.path) {
      userRules = try String(contentsOf: userRulesURL, encoding: .utf8)
    }
    let snapshot = try LegacySnapshot(propertyList: values, userRules: userRules)
    return snapshot.hasPersistedEvidence ? snapshot : nil
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

protocol LegacyActivationStoring {
  func loadActiveTargetID() throws -> NodeID?
  func save(activeTargetID: NodeID?) throws
}

extension ActivationStateFileStore: LegacyActivationStoring {}

enum LegacyActiveTargetResult: Equatable, Sendable {
  case imported(NodeID)
  case cleared(reason: String)
}

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
  let migratedPreferences: [String]
  let activeTarget: LegacyActiveTargetResult
  let warnings: [String]
}

struct LegacyImportOutcome: Equatable, Sendable {
  let groupID: NodeID
  let activeTargetID: NodeID?
  let preferredMode: ProxyModeKind
  let loginAtLogin: Bool?
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
  let settings: ProxySettings
  let activeTargetID: NodeID?
  let preferredMode: ProxyModeKind
  let loginAtLogin: Bool?
  let credentials: [CredentialReference: String]
  let report: LegacyImportReport
}

/// Pure planning seam: translates one immutable Legacy snapshot into a new
/// manual subtree and a validated 2.0 preference snapshot. No writes occur here.
struct LegacyImportPlanner {
  static func makePlan(
    snapshot: LegacySnapshot,
    existingDocument: CatalogDocument,
    existingSettings: ProxySettings
  ) throws -> LegacyImportPlan {
    var catalog = existingDocument.catalog
    let groupName = nextGroupName(in: catalog)
    let groupID = try catalog.addGroup(groupName)
    let serverImport = try importServers(snapshot.profiles, into: &catalog, groupID: groupID)
    let active = activeTarget(
      for: snapshot.activeProfileID, importedIDs: serverImport.importedIDsByLegacyID)

    var settings = existingSettings
    var migratedPreferences: [String] = []
    var warnings: [String] = []
    migrateListenSettings(
      snapshot, into: &settings, migrated: &migratedPreferences, warnings: &warnings)
    migrateGeneralSettings(
      snapshot, into: &settings, migrated: &migratedPreferences, warnings: &warnings)
    let preferredMode = migrateModeSettings(
      snapshot, into: &settings, migrated: &migratedPreferences, warnings: &warnings)

    let report = LegacyImportReport(
      groupName: groupName,
      importedServerCount: serverImport.importedServerCount,
      skippedRecords: serverImport.skippedRecords,
      regeneratedIdentityCount: serverImport.regeneratedIdentityCount,
      migratedPreferences: migratedPreferences,
      activeTarget: active.result,
      warnings: warnings)
    return LegacyImportPlan(
      groupID: groupID,
      document: CatalogDocument(catalog: catalog, subscriptions: existingDocument.subscriptions),
      settings: settings,
      activeTargetID: active.id,
      preferredMode: preferredMode,
      loginAtLogin: snapshot.loginAtLogin,
      credentials: serverImport.credentials,
      report: report)
  }
}

extension LegacyImportPlanner {
  private struct ServerImportResult {
    let importedIDsByLegacyID: [String: [NodeID]]
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
    var importedIDsByLegacyID: [String: [NodeID]] = [:]
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
      if let rawID = profile.id {
        importedIDsByLegacyID[legacyIdentityKey(rawID), default: []].append(nodeID)
      }
    }

    return ServerImportResult(
      importedIDsByLegacyID: importedIDsByLegacyID,
      credentials: credentials,
      skippedRecords: skippedRecords,
      regeneratedIdentityCount: regeneratedIdentityCount,
      importedServerCount: importedServerCount)
  }

  private static func activeTarget(
    for legacyID: String?,
    importedIDs: [String: [NodeID]]
  ) -> (id: NodeID?, result: LegacyActiveTargetResult) {
    guard let legacyID else {
      return (nil, .cleared(reason: "Legacy 没有活动服务器"))
    }
    let matches = importedIDs[legacyIdentityKey(legacyID)] ?? []
    guard matches.count == 1, let match = matches.first else {
      let reason = matches.isEmpty ? "活动服务器未能唯一映射" : "活动服务器身份重复，无法唯一映射"
      return (nil, .cleared(reason: reason))
    }
    return (match, .imported(match))
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

  private static func migrateListenSettings(
    _ snapshot: LegacySnapshot,
    into settings: inout ProxySettings,
    migrated: inout [String],
    warnings: inout [String]
  ) {
    let originalListen = settings.listen
    var listen = settings.listen
    if let port = snapshot.socksPort {
      listen.socksPort = port
      migrated.append("SOCKS 端口")
    }
    if let port = snapshot.httpPort {
      listen.httpPort = port
      migrated.append("HTTP 端口")
    }
    if let port = snapshot.pacPort {
      listen.pacPort = port
      migrated.append("PAC 端口")
    }
    if let enabled = snapshot.httpEnabled {
      listen.httpProxyEnabled = enabled
      migrated.append("HTTP 监听开关")
    }
    if let enabled = snapshot.udpRelayEnabled {
      listen.udpRelayEnabled = enabled
      migrated.append("UDP 中继")
    }
    if !listen.portValidationErrors().isEmpty {
      listen = originalListen
      warnings.append("Legacy 端口配置无效，端口保持 2.0 当前值")
    }

    let addresses = [snapshot.socksAddress, snapshot.httpAddress].compactMap { $0 }
    let nonLoopbackAddress = addresses.contains { !isLoopbackAddress($0) }
    let inconsistentAddresses = Set(addresses.map { $0.lowercased() }).count > 1
    if nonLoopbackAddress || inconsistentAddresses || snapshot.pacBindsToLocalhost == false {
      warnings.append("Legacy 监听地址不是统一回环地址，已导入为回环监听")
    }
    // A Legacy import must never expose the new unauthenticated host scope by
    // accident. The user can explicitly choose host scope later in Settings.
    listen.scope = .loopback
    settings.listen = listen
  }

  private static func migrateGeneralSettings(
    _ snapshot: LegacySnapshot,
    into settings: inout ProxySettings,
    migrated: inout [String],
    warnings: inout [String]
  ) {
    if let timeout = snapshot.timeoutSeconds {
      if (1...86_400).contains(timeout) {
        settings.timeoutSeconds = timeout
        migrated.append("超时")
      } else {
        warnings.append("Legacy 超时无效，保持 2.0 当前值")
      }
    }
    if let verbose = snapshot.verboseLogging {
      settings.verboseLogging = verbose
      migrated.append("verbose")
    }
    if let exceptions = snapshot.proxyExceptions {
      settings.proxyExceptions = exceptions
      migrated.append("绕过列表")
    }
    if let rules = snapshot.pacUserRules {
      settings.pacUserRules = rules
      migrated.append("PAC 用户规则")
    }
    if let externalPACURL = snapshot.externalPACURL {
      if externalPACURL.isEmpty || validRemoteURL(externalPACURL, externalPAC: true) {
        settings.externalPACURL = externalPACURL
        migrated.append("外部 PAC URL")
      } else {
        warnings.append("Legacy 外部 PAC URL 不受 2.0 支持，未迁移")
      }
    }
    if let gfwListURL = snapshot.gfwListURL {
      if gfwListURL.isEmpty || validRemoteURL(gfwListURL, externalPAC: false) {
        settings.gfwListURL = gfwListURL
        migrated.append("GFW List URL")
      } else {
        warnings.append("Legacy GFW List URL 无效，未迁移")
      }
    }
  }

  private static func migrateModeSettings(
    _ snapshot: LegacySnapshot,
    into settings: inout ProxySettings,
    migrated: inout [String],
    warnings: inout [String]
  ) -> ProxyModeKind {
    var enabledModes = settings.enabledModes
    if let value = snapshot.modeAvailability.pac {
      if value { enabledModes.insert(.pac) } else { enabledModes.remove(.pac) }
    }
    if let value = snapshot.modeAvailability.global {
      if value { enabledModes.insert(.global) } else { enabledModes.remove(.global) }
    }
    if let value = snapshot.modeAvailability.manual {
      if value { enabledModes.insert(.manual) } else { enabledModes.remove(.manual) }
    }
    if let value = snapshot.modeAvailability.externalPAC {
      if value { enabledModes.insert(.externalPAC) } else { enabledModes.remove(.externalPAC) }
    }
    if snapshot.modeAvailability.hasPersistedValue {
      settings.enabledModes = enabledModes
      migrated.append("可切换模式项")
    }

    guard let rawMode = snapshot.runningMode?.lowercased() else {
      return settings.preferredMode
    }
    let preferredMode: ProxyModeKind?
    switch rawMode {
    case "auto", "pac": preferredMode = .pac
    case "global": preferredMode = .global
    case "manual": preferredMode = .manual
    case "externalpac":
      if snapshot.externalPACURL?.isEmpty == false,
        validRemoteURL(snapshot.externalPACURL ?? "", externalPAC: true)
      {
        preferredMode = .externalPAC
      } else {
        preferredMode = nil
        warnings.append("Legacy 当前模式是外部 PAC，但 URL 无法迁移；当前模式保持 PAC")
      }
    default:
      preferredMode = nil
      warnings.append("Legacy 当前代理模式未知，当前模式保持 2.0 当前值")
    }
    guard let preferredMode else { return settings.preferredMode }
    settings.preferredMode = preferredMode
    migrated.append("当前代理模式")
    return preferredMode
  }

  private static func validRemoteURL(_ value: String, externalPAC: Bool) -> Bool {
    guard let url = URL(string: value) else { return false }
    if externalPAC {
      return (try? ProxyMode.validateExternalPACURL(url)) != nil
    }
    guard let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
      url.host != nil, url.user == nil, url.password == nil
    else { return false }
    return value.utf8.count <= 2_048
  }

  private static func isLoopbackAddress(_ value: String) -> Bool {
    let normalized = value.lowercased()
    if normalized == "localhost" || normalized == "::1" || normalized == "127.0.0.1" {
      return true
    }
    var ipv4 = in_addr()
    if normalized.withCString({ inet_pton(AF_INET, $0, &ipv4) }) == 1 {
      return ipv4.s_addr == UInt32(0x0100_007F).bigEndian
    }
    return false
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

/// Coordinates the pure plan with all persistent stores. Each store is written
/// only after the plan is complete; any later failure restores every prior
/// value, including Keychain entries and the completion marker.
final class LegacyImportService {
  private let source: LegacySnapshotProviding
  private let catalogStore: LegacyCatalogStoring
  private let settingsStore: ProxySettingsStoring
  private let activationStore: LegacyActivationStoring
  private let credentials: CredentialStoring
  private let marker: LegacyImportMarkerStoring

  init(
    source: LegacySnapshotProviding = UserDefaultsLegacySnapshotProvider(),
    catalogStore: LegacyCatalogStoring = CatalogFileStore(
      fileURL: CatalogFileStore.defaultFileURL()),
    settingsStore: ProxySettingsStoring = ProxySettingsFileStore(),
    activationStore: LegacyActivationStoring = ActivationStateFileStore(
      fileURL: ActivationStateFileStore.defaultFileURL()),
    credentials: CredentialStoring = KeychainCredentialStore(),
    marker: LegacyImportMarkerStoring = UserDefaultsLegacyImportMarkerStore()
  ) {
    self.source = source
    self.catalogStore = catalogStore
    self.settingsStore = settingsStore
    self.activationStore = activationStore
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
    let originalSettings = try settingsStore.load()
    let originalActiveTargetID = try activationStore.loadActiveTargetID()
    let plan = try LegacyImportPlanner.makePlan(
      snapshot: snapshot, existingDocument: originalDocument, existingSettings: originalSettings)
    let touchedReferences = Set(plan.credentials.keys).union([
      ProxySettingsFileStore.externalPACReference,
      ProxySettingsFileStore.gfwListReference,
    ])
    var originalSecrets: [CredentialReference: String?] = [:]
    for reference in touchedReferences {
      originalSecrets[reference] = try credentials.secret(for: reference)
    }

    do {
      for (reference, secret) in plan.credentials {
        try credentials.save(secret, for: reference)
      }
      try catalogStore.save(plan.document)
      try settingsStore.save(plan.settings)
      try activationStore.save(activeTargetID: plan.activeTargetID)
      try marker.setCompleted(true)
    } catch {
      let rollbackFailures = rollback(
        originalDocument: originalDocument,
        originalSettings: originalSettings,
        originalActiveTargetID: originalActiveTargetID,
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
      activeTargetID: plan.activeTargetID,
      preferredMode: plan.preferredMode,
      loginAtLogin: plan.loginAtLogin,
      report: plan.report)
  }
}

extension LegacyImportService {
  fileprivate func rollback(
    originalDocument: CatalogDocument,
    originalSettings: ProxySettings,
    originalActiveTargetID: NodeID?,
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
      try activationStore.save(activeTargetID: originalActiveTargetID)
    } catch {
      failures.append("活动目标：\(error)")
    }
    do {
      try settingsStore.save(originalSettings)
    } catch {
      failures.append("偏好：\(error)")
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
