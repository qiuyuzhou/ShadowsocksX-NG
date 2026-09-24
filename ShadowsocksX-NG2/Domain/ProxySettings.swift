import Darwin
import Foundation

/// #33 的用户偏好快照。监听端点仍是运行时契约的输入，但不会把偏好文件
/// 当作运行时文件使用；代理启动前由控制器从快照重新派生完整契约。
struct ProxySettings: Equatable, Sendable {
  static let defaultGFWListURL = "https://cdn.jsdelivr.net/gh/gfwlist/gfwlist/gfwlist.txt"
  static let defaultProxyExceptions =
    "127.0.0.1, localhost, 192.168.0.0/16, 10.0.0/8, FE80::/64, ::1, FD00::/8"

  var listen: SslocalListenSettings
  var timeoutSeconds: Int
  var verboseLogging: Bool
  var proxyExceptions: String
  var gfwListURL: String
  var pacUserRules: String
  /// The persisted current mode: the mode selector's choice survives GUI
  /// restarts.
  var preferredMode: ProxyModeKind

  init(
    listen: SslocalListenSettings = SslocalListenSettings(),
    timeoutSeconds: Int = 60,
    verboseLogging: Bool = false,
    proxyExceptions: String = ProxySettings.defaultProxyExceptions,
    gfwListURL: String = ProxySettings.defaultGFWListURL,
    pacUserRules: String = "",
    preferredMode: ProxyModeKind = .pac
  ) {
    self.listen = listen
    self.timeoutSeconds = timeoutSeconds
    self.verboseLogging = verboseLogging
    self.proxyExceptions = proxyExceptions
    self.gfwListURL = gfwListURL
    self.pacUserRules = pacUserRules
    self.preferredMode = preferredMode
  }

  /// 系统代理的 ExceptionsList；输入顺序保留，重复项只保留第一次出现的值。
  var proxyExceptionList: [String] {
    var result: [String] = []
    var seen = Set<String>()
    for value in proxyExceptions.split(whereSeparator: { character in
      character == "," || character == "、" || character.isWhitespace
    }) {
      let item = String(value)
      let identity = item.lowercased()
      guard !item.isEmpty, seen.insert(identity).inserted else { continue }
      result.append(item)
    }
    return result
  }

  var validationErrors: [ProxySettingsValidationError] {
    var errors = listen.portValidationErrors().map(ProxySettingsValidationError.init)
    if !(1...86_400).contains(timeoutSeconds) {
      errors.append(.invalidTimeout(timeoutSeconds))
    }
    if case .host(let address) = listen.scope, !Self.isUsableHostAddress(address) {
      errors.append(.invalidHostAddress(address))
    }
    if !gfwListURL.isEmpty, !Self.isUsableRemoteURL(gfwListURL) {
      errors.append(.invalidGFWListURL(gfwListURL))
    }
    return errors
  }

  private static func isUsableRemoteURL(_ value: String) -> Bool {
    guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
      scheme == "http" || scheme == "https", url.host != nil,
      url.user == nil, url.password == nil
    else { return false }
    return value.utf8.count <= 2048
  }

  private static func isUsableHostAddress(_ value: String) -> Bool {
    guard value != "0.0.0.0", value != "127.0.0.1" else { return false }
    var address = in_addr()
    return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
  }
}

/// 设置快照的点名校验错误；端口错误保留 D8 的端点与数值信息。
enum ProxySettingsValidationError: Error, Equatable, Sendable {
  case portOutOfRange(endpoint: ProxyEndpointKind, port: Int)
  case duplicatePort(endpoint: ProxyEndpointKind, otherEndpoint: ProxyEndpointKind, port: Int)
  case invalidTimeout(Int)
  case invalidHostAddress(String)
  case invalidGFWListURL(String)

  init(_ error: PortSettingError) {
    switch error {
    case .portOutOfRange(let endpoint, let port):
      self = .portOutOfRange(endpoint: endpoint, port: port)
    case .duplicatePort(let endpoint, let otherEndpoint, let port):
      self = .duplicatePort(endpoint: endpoint, otherEndpoint: otherEndpoint, port: port)
    }
  }

}

protocol ProxySettingsStoring {
  func load() throws -> ProxySettings
  func save(_ settings: ProxySettings) throws
  func reset() throws
}

enum ProxySettingsStoreError: Error, Equatable {
  case corrupt(detail: String)
  case invalid([ProxySettingsValidationError])
  case ioFailure(detail: String)
  case missingCredential(CredentialReference)
  case credentialFailure(detail: String)
  case rollbackFailed
  case legacyListenSettings(ListenSettingsStoreError)
}

struct RestoredProxySettings: Equatable {
  let settings: ProxySettings
  let unreadableError: ProxySettingsStoreError?
}

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
        preferredMode: record.preferredMode))
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
  }
}

extension ProxySettingsRecord {
  fileprivate enum CodingKeys: String, CodingKey {
    case scopeKind, advertisedAddress, socksPort, httpPort, pacPort
    case timeoutSeconds, verboseLogging, proxyExceptions
    case gfwListCredentialReference, gfwListURLConfigured
    case pacUserRules, preferredMode
  }
}
