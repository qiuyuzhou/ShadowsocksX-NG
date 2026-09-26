import Foundation

/// #33 偏好存储。非敏感字段写入受保护的 JSON；GFW URL 只把固定引用写入
/// JSON，真实值由 KeychainCredentialStore 持有。
struct ProxySettingsFileStore: ProxySettingsStoring {
  static let gfwListReference =
    CredentialReference(rawValue: "settings.gfw-list-url")

  let fileURL: URL
  let legacyListenFileURL: URL
  let credentials: CredentialStoring

  init(
    fileURL: URL = ProxySettingsFileStore.defaultFileURL(),
    legacyListenFileURL: URL = ListenSettingsFileStore.defaultFileURL(),
    credentials: CredentialStoring = KeychainCredentialStore()
  ) {
    self.fileURL = fileURL
    self.legacyListenFileURL = legacyListenFileURL
    self.credentials = credentials
  }

  static func defaultFileURL() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    return support.appendingPathComponent("ShadowsocksX-NG2/settings.json")
  }

  func load() throws -> ProxySettings {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      do {
        let listen = try ListenSettingsFileStore(fileURL: legacyListenFileURL).load()
        return try validated(ProxySettings(listen: listen))
      } catch let error as ListenSettingsStoreError {
        throw ProxySettingsStoreError.legacyListenSettings(error)
      } catch let error as ProxySettingsStoreError {
        throw error
      } catch {
        throw ProxySettingsStoreError.ioFailure(detail: String(describing: error))
      }
    }

    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw ProxySettingsStoreError.ioFailure(detail: String(describing: error))
    }
    let record: ProxySettingsRecord
    do {
      record = try JSONDecoder().decode(ProxySettingsRecord.self, from: data)
    } catch {
      throw ProxySettingsStoreError.corrupt(detail: String(describing: error))
    }
    return try settings(from: record)
  }

  func save(_ settings: ProxySettings) throws {
    _ = try validated(settings)
    var journal = CredentialWriteJournal(credentials: credentials)
    do {
      if settings.gfwListURL.isEmpty {
        try journal.deleteOrThrow(Self.gfwListReference)
      } else {
        try journal.save(settings.gfwListURL, for: Self.gfwListReference)
      }
      let data = try Self.jsonEncoder.encode(record(from: settings))
      try AtomicFileWriter.write(data, to: fileURL)
    } catch let error as ProxySettingsStoreError {
      throw transactionalFailure(error, journal: journal)
    } catch let error as AtomicFileWriter.WriteError {
      throw transactionalFailure(
        .ioFailure(detail: String(describing: error)), journal: journal)
    } catch let error as CredentialStoreError {
      throw transactionalFailure(
        .credentialFailure(detail: String(describing: error)), journal: journal)
    } catch {
      throw transactionalFailure(
        .ioFailure(detail: String(describing: error)), journal: journal)
    }
  }

  func reset() throws {
    let settingsSnapshot = try fileSnapshot(at: fileURL)
    let legacySnapshot = try fileSnapshot(at: legacyListenFileURL)
    var journal = CredentialWriteJournal(credentials: credentials)
    do {
      try journal.deleteOrThrow(Self.gfwListReference)
      try removeIfPresent(fileURL)
      try removeIfPresent(legacyListenFileURL)
    } catch {
      let filesRestored =
        restore(settingsSnapshot, at: fileURL)
        && restore(legacySnapshot, at: legacyListenFileURL)
      let credentialsRestored: Bool
      switch journal.rollback() {
      case .partial:
        credentialsRestored = false
      case .nothingToRestore, .restored:
        credentialsRestored = true
      }
      guard filesRestored && credentialsRestored else {
        throw ProxySettingsStoreError.rollbackFailed
      }
      throw asStoreError(error)
    }
  }

  static func restored(store: ProxySettingsFileStore = ProxySettingsFileStore())
    -> RestoredProxySettings
  {
    do {
      return RestoredProxySettings(settings: try store.load(), unreadableError: nil)
    } catch let error as ProxySettingsStoreError {
      RuntimeLog.emit(.listenSettingsUnreadable(detail: String(describing: error)))
      return RestoredProxySettings(settings: ProxySettings(), unreadableError: error)
    } catch {
      let wrapped = ProxySettingsStoreError.ioFailure(detail: String(describing: error))
      RuntimeLog.emit(.listenSettingsUnreadable(detail: String(describing: error)))
      return RestoredProxySettings(settings: ProxySettings(), unreadableError: wrapped)
    }
  }

  private func validated(_ settings: ProxySettings) throws -> ProxySettings {
    let errors = settings.validationErrors
    guard errors.isEmpty else { throw ProxySettingsStoreError.invalid(errors) }
    return settings
  }

  private func requiredSecret(for reference: CredentialReference) throws -> String {
    do {
      guard let secret = try credentials.secret(for: reference) else {
        throw ProxySettingsStoreError.missingCredential(reference)
      }
      return secret
    } catch let error as ProxySettingsStoreError {
      throw error
    } catch {
      throw ProxySettingsStoreError.credentialFailure(detail: String(describing: error))
    }
  }

  private func settings(from record: ProxySettingsRecord) throws -> ProxySettings {
    var listen = SslocalListenSettings()
    switch record.scopeKind {
    case .loopback:
      listen.scope = .loopback
    case .host:
      guard let address = record.advertisedAddress else {
        throw ProxySettingsStoreError.corrupt(detail: "主机监听缺少 advertisedAddress")
      }
      listen.scope = .host(advertisedAddress: address)
    }
    listen.socksPort = record.socksPort
    listen.httpPort = record.httpPort
    listen.pacPort = record.pacPort

    let gfwListURL: String
    if let reference = record.gfwListCredentialReference {
      gfwListURL = try requiredSecret(for: reference)
    } else {
      gfwListURL = record.gfwListURLConfigured ? "" : ProxySettings.defaultGFWListURL
    }
    return try validated(
      ProxySettings(
        listen: listen,
        timeoutSeconds: record.timeoutSeconds,
        verboseLogging: record.verboseLogging,
        proxyExceptions: record.proxyExceptions,
        gfwListURL: gfwListURL,
        pacUserRules: record.pacUserRules,
        preferredMode: record.preferredMode,
        ruleDefaultAction: record.ruleDefaultAction,
        agentEnabled: record.agentEnabled,
        systemProxyEnabled: record.systemProxyEnabled))
  }

  private func record(from settings: ProxySettings) -> ProxySettingsRecord {
    var record = ProxySettingsRecord()
    record.scopeKind = settings.listen.scope.kind
    record.advertisedAddress = {
      if case .host(let address) = settings.listen.scope { return address }
      return nil
    }()
    record.socksPort = settings.listen.socksPort
    record.httpPort = settings.listen.httpPort
    record.pacPort = settings.listen.pacPort
    record.timeoutSeconds = settings.timeoutSeconds
    record.verboseLogging = settings.verboseLogging
    record.proxyExceptions = settings.proxyExceptions
    record.gfwListCredentialReference =
      settings.gfwListURL.isEmpty ? nil : Self.gfwListReference
    record.gfwListURLConfigured = true
    record.pacUserRules = settings.pacUserRules
    record.preferredMode = settings.preferredMode
    record.ruleDefaultAction = settings.ruleDefaultAction
    record.agentEnabled = settings.agentEnabled
    record.systemProxyEnabled = settings.systemProxyEnabled
    return record
  }

  private static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  private func transactionalFailure(
    _ error: ProxySettingsStoreError,
    journal: CredentialWriteJournal
  ) -> ProxySettingsStoreError {
    if case .partial = journal.rollback() {
      return .rollbackFailed
    }
    return error
  }

  private func asStoreError(_ error: Error) -> ProxySettingsStoreError {
    if let error = error as? ProxySettingsStoreError { return error }
    if let error = error as? CredentialStoreError {
      return .credentialFailure(detail: String(describing: error))
    }
    return .ioFailure(detail: String(describing: error))
  }

  private func fileSnapshot(at url: URL) throws -> Data? {
    guard FileManager.default.fileExists(atPath: url.path) else { return nil }
    do {
      return try Data(contentsOf: url)
    } catch {
      throw ProxySettingsStoreError.ioFailure(detail: String(describing: error))
    }
  }

  private func removeIfPresent(_ url: URL) throws {
    guard FileManager.default.fileExists(atPath: url.path) else { return }
    do {
      try FileManager.default.removeItem(at: url)
    } catch {
      throw ProxySettingsStoreError.ioFailure(detail: String(describing: error))
    }
  }

  private func restore(_ snapshot: Data?, at url: URL) -> Bool {
    guard let snapshot else {
      guard FileManager.default.fileExists(atPath: url.path) else { return true }
      do {
        try FileManager.default.removeItem(at: url)
        return true
      } catch {
        return false
      }
    }
    do {
      try AtomicFileWriter.write(snapshot, to: url)
      return true
    } catch {
      return false
    }
  }
}

private struct ProxySettingsRecord: Codable, Equatable, Sendable {
  var scopeKind: ListenScopeKind = .loopback
  var advertisedAddress: String?
  var socksPort: Int = SslocalListenSettings.defaultSocksPort
  var httpPort: Int = SslocalListenSettings.defaultHTTPPort
  var pacPort: Int = SslocalListenSettings.defaultPACPort
  var timeoutSeconds: Int = 60
  var verboseLogging: Bool = false
  var proxyExceptions: String = ProxySettings.defaultProxyExceptions
  var gfwListCredentialReference: CredentialReference?
  var gfwListURLConfigured: Bool = false
  var pacUserRules: String = ""
  var preferredMode: ProxyModeKind = .pac
  var ruleDefaultAction: RuleDefaultAction = .proxyWhenUnmatched
  var agentEnabled: Bool = true
  var systemProxyEnabled: Bool = false

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    scopeKind = try container.decodeIfPresent(ListenScopeKind.self, forKey: .scopeKind) ?? .loopback
    advertisedAddress = try container.decodeIfPresent(String.self, forKey: .advertisedAddress)
    socksPort =
      try container.decodeIfPresent(Int.self, forKey: .socksPort)
      ?? SslocalListenSettings.defaultSocksPort
    httpPort =
      try container.decodeIfPresent(Int.self, forKey: .httpPort)
      ?? SslocalListenSettings.defaultHTTPPort
    pacPort =
      try container.decodeIfPresent(Int.self, forKey: .pacPort)
      ?? SslocalListenSettings.defaultPACPort
    timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
    verboseLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
    proxyExceptions =
      try container.decodeIfPresent(String.self, forKey: .proxyExceptions)
      ?? ProxySettings.defaultProxyExceptions
    gfwListCredentialReference = try container.decodeIfPresent(
      CredentialReference.self, forKey: .gfwListCredentialReference)
    gfwListURLConfigured =
      try container.decodeIfPresent(Bool.self, forKey: .gfwListURLConfigured) ?? false
    pacUserRules = try container.decodeIfPresent(String.self, forKey: .pacUserRules) ?? ""
    preferredMode =
      try container.decodeIfPresent(ProxyModeKind.self, forKey: .preferredMode) ?? .pac
    // 规则模式子选项（issue #63）：出厂「未匹配时代理」。
    ruleDefaultAction =
      try container.decodeIfPresent(RuleDefaultAction.self, forKey: .ruleDefaultAction)
      ?? .proxyWhenUnmatched
    // 首次运行缺省：agent 默认开启，系统代理默认关闭（issue #60）。
    agentEnabled = try container.decodeIfPresent(Bool.self, forKey: .agentEnabled) ?? true
    systemProxyEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .systemProxyEnabled) ?? false
  }
}

extension ProxySettingsRecord {
  fileprivate enum CodingKeys: String, CodingKey {
    case scopeKind, advertisedAddress, socksPort, httpPort, pacPort
    case timeoutSeconds, verboseLogging, proxyExceptions
    case gfwListCredentialReference, gfwListURLConfigured
    case pacUserRules, preferredMode
    case ruleDefaultAction
    case agentEnabled, systemProxyEnabled
  }
}
