import Darwin
import Foundation

/// #33 的用户偏好快照。监听端点仍是运行时契约的输入，但不会把偏好文件
/// 当作运行时文件使用；代理启动前由控制器从快照重新派生完整契约。
struct ProxySettings: Equatable, Sendable {
  static let defaultGFWListURL = "https://cdn.jsdelivr.net/gh/gfwlist/gfwlist/gfwlist.txt"
  static let defaultProxyExceptions =
    "127.0.0.1, localhost, 192.168.0.0/16, 10.0.0.0/8, FE80::/64, ::1, FD00::/8"
  static let defaultEnabledModes: Set<ProxyModeKind> = [.pac, .global, .manual]

  var listen: SslocalListenSettings
  var timeoutSeconds: Int
  var verboseLogging: Bool
  var proxyExceptions: String
  var externalPACURL: String
  var gfwListURL: String
  var pacUserRules: String
  /// Mode selected after a restart. An external PAC URL is resolved from
  /// `externalPACURL` when this kind is `.externalPAC`.
  var preferredMode: ProxyModeKind
  /// The set is used by the menu/settings views to keep disabled modes out of
  /// the cycle.
  var enabledModes: Set<ProxyModeKind>

  init(
    listen: SslocalListenSettings = SslocalListenSettings(),
    timeoutSeconds: Int = 60,
    verboseLogging: Bool = false,
    proxyExceptions: String = ProxySettings.defaultProxyExceptions,
    externalPACURL: String = "",
    gfwListURL: String = ProxySettings.defaultGFWListURL,
    pacUserRules: String = "",
    preferredMode: ProxyModeKind = .pac,
    enabledModes: Set<ProxyModeKind> = ProxySettings.defaultEnabledModes
  ) {
    self.listen = listen
    self.timeoutSeconds = timeoutSeconds
    self.verboseLogging = verboseLogging
    self.proxyExceptions = proxyExceptions
    self.externalPACURL = externalPACURL
    self.gfwListURL = gfwListURL
    self.pacUserRules = pacUserRules
    self.preferredMode = preferredMode
    self.enabledModes = enabledModes
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
    if !externalPACURL.isEmpty, let error = Self.externalPACError(for: externalPACURL) {
      errors.append(.invalidExternalPACURL(error))
    }
    if !gfwListURL.isEmpty, !Self.isUsableRemoteURL(gfwListURL) {
      errors.append(.invalidGFWListURL(gfwListURL))
    }
    return errors
  }

  private static func externalPACError(for value: String) -> ProxyModeError? {
    guard let url = URL(string: value) else {
      return .externalPACURLHasNoScheme
    }
    do {
      try ProxyMode.validateExternalPACURL(url)
      return nil
    } catch let error as ProxyModeError {
      return error
    } catch {
      return .externalPACURLHasNoScheme
    }
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
  case invalidExternalPACURL(ProxyModeError)
  case invalidGFWListURL(String)

  init(_ error: PortSettingError) {
    switch error {
    case .portOutOfRange(let endpoint, let port):
      self = .portOutOfRange(endpoint: endpoint, port: port)
    case .duplicatePort(let endpoint, let otherEndpoint, let port):
      self = .duplicatePort(endpoint: endpoint, otherEndpoint: otherEndpoint, port: port)
    }
  }

  var presentedReason: String {
    switch self {
    case .portOutOfRange(let endpoint, let port):
      return PortSettingError.portOutOfRange(endpoint: endpoint, port: port).presentedReason
    case .duplicatePort(let endpoint, let otherEndpoint, let port):
      return PortSettingError.duplicatePort(
        endpoint: endpoint, otherEndpoint: otherEndpoint, port: port
      ).presentedReason
    case .invalidTimeout(let seconds):
      return "超时 " + String(seconds) + " 秒无效，必须是 1–86400 之间的整数"
    case .invalidHostAddress(let address):
      return "主机地址 " + address + " 无效，必须是非回环 IPv4 地址"
    case .invalidExternalPACURL(let error):
      return "外部 PAC URL 无效：" + error.presentedReason
    case .invalidGFWListURL(let value):
      return "GFW List URL 无效：" + value
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
  case legacyListenSettings(ListenSettingsStoreError)

  var presentedReason: String {
    switch self {
    case .corrupt:
      return "偏好文件损坏"
    case .invalid(let errors):
      return errors.map(\.presentedReason).joined(separator: "；")
    case .ioFailure:
      return "偏好文件读写失败"
    case .missingCredential:
      return "偏好中的敏感 URL 无法从钥匙串读取"
    case .credentialFailure:
      return "偏好中的敏感 URL 无法写入钥匙串"
    case .legacyListenSettings(let error):
      return "旧版监听设置无法读取：\(error.presentedReason)"
    }
  }
}

struct RestoredProxySettings: Equatable {
  let settings: ProxySettings
  let unreadableError: ProxySettingsStoreError?
}

/// #33 偏好存储。非敏感字段写入受保护的 JSON；外部 PAC 与 GFW URL 只把
/// 固定引用写入 JSON，真实值由 KeychainCredentialStore 持有。
struct ProxySettingsFileStore: ProxySettingsStoring {
  static let externalPACReference =
    CredentialReference(rawValue: "settings.external-pac-url")
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
    try validated(settings)
    do {
      try saveOrDelete(settings.externalPACURL, reference: Self.externalPACReference)
      try saveOrDelete(settings.gfwListURL, reference: Self.gfwListReference)
    } catch let error as ProxySettingsStoreError {
      throw error
    } catch {
      throw ProxySettingsStoreError.credentialFailure(detail: String(describing: error))
    }

    do {
      let data = try Self.jsonEncoder.encode(record(from: settings))
      try AtomicFileWriter.write(data, to: fileURL)
    } catch let error as AtomicFileWriter.WriteError {
      throw ProxySettingsStoreError.ioFailure(detail: String(describing: error))
    } catch {
      throw ProxySettingsStoreError.ioFailure(detail: String(describing: error))
    }
  }

  func reset() throws {
    do {
      try credentials.delete(Self.externalPACReference)
      try credentials.delete(Self.gfwListReference)
      for url in [fileURL, legacyListenFileURL]
      where FileManager.default.fileExists(atPath: url.path) {
        try FileManager.default.removeItem(at: url)
      }
    } catch {
      throw ProxySettingsStoreError.ioFailure(detail: String(describing: error))
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

  private func saveOrDelete(_ secret: String, reference: CredentialReference) throws {
    do {
      if secret.isEmpty {
        try credentials.delete(reference)
      } else {
        try credentials.save(secret, for: reference)
      }
    } catch {
      throw ProxySettingsStoreError.credentialFailure(detail: String(describing: error))
    }
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
    listen.httpProxyEnabled = record.httpProxyEnabled
    listen.httpPort = record.httpPort
    listen.pacPort = record.pacPort
    listen.udpRelayEnabled = record.udpRelayEnabled

    let externalPACURL =
      if let reference = record.externalPACCredentialReference {
        try requiredSecret(for: reference)
      } else {
        ""
      }
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
        externalPACURL: externalPACURL,
        gfwListURL: gfwListURL,
        pacUserRules: record.pacUserRules,
        preferredMode: record.preferredMode,
        enabledModes: Set(record.enabledModes)))
  }

  private func record(from settings: ProxySettings) -> ProxySettingsRecord {
    var record = ProxySettingsRecord()
    record.scopeKind = settings.listen.scope.kind
    record.advertisedAddress = {
      if case .host(let address) = settings.listen.scope { return address }
      return nil
    }()
    record.socksPort = settings.listen.socksPort
    record.httpProxyEnabled = settings.listen.httpProxyEnabled
    record.httpPort = settings.listen.httpPort
    record.pacPort = settings.listen.pacPort
    record.udpRelayEnabled = settings.listen.udpRelayEnabled
    record.timeoutSeconds = settings.timeoutSeconds
    record.verboseLogging = settings.verboseLogging
    record.proxyExceptions = settings.proxyExceptions
    record.externalPACCredentialReference =
      settings.externalPACURL.isEmpty ? nil : Self.externalPACReference
    record.gfwListCredentialReference =
      settings.gfwListURL.isEmpty ? nil : Self.gfwListReference
    record.gfwListURLConfigured = true
    record.pacUserRules = settings.pacUserRules
    record.preferredMode = settings.preferredMode
    record.enabledModes = settings.enabledModes.sorted { $0.rawValue < $1.rawValue }
    return record
  }

  private static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()
}

private struct ProxySettingsRecord: Codable, Equatable, Sendable {
  var scopeKind: ListenScopeKind = .loopback
  var advertisedAddress: String?
  var socksPort: Int = SslocalListenSettings.defaultSocksPort
  var httpProxyEnabled: Bool = true
  var httpPort: Int = SslocalListenSettings.defaultHTTPPort
  var pacPort: Int = SslocalListenSettings.defaultPACPort
  var udpRelayEnabled: Bool = false
  var timeoutSeconds: Int = 60
  var verboseLogging: Bool = false
  var proxyExceptions: String = ProxySettings.defaultProxyExceptions
  var externalPACCredentialReference: CredentialReference?
  var gfwListCredentialReference: CredentialReference?
  var gfwListURLConfigured: Bool = false
  var pacUserRules: String = ""
  var preferredMode: ProxyModeKind = .pac
  var enabledModes: [ProxyModeKind] = ProxySettings.defaultEnabledModes.sorted {
    $0.rawValue < $1.rawValue
  }

  init() {}

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    scopeKind = try container.decodeIfPresent(ListenScopeKind.self, forKey: .scopeKind) ?? .loopback
    advertisedAddress = try container.decodeIfPresent(String.self, forKey: .advertisedAddress)
    socksPort =
      try container.decodeIfPresent(Int.self, forKey: .socksPort)
      ?? SslocalListenSettings.defaultSocksPort
    httpProxyEnabled = try container.decodeIfPresent(Bool.self, forKey: .httpProxyEnabled) ?? true
    httpPort =
      try container.decodeIfPresent(Int.self, forKey: .httpPort)
      ?? SslocalListenSettings.defaultHTTPPort
    pacPort =
      try container.decodeIfPresent(Int.self, forKey: .pacPort)
      ?? SslocalListenSettings.defaultPACPort
    udpRelayEnabled = try container.decodeIfPresent(Bool.self, forKey: .udpRelayEnabled) ?? false
    timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
    verboseLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
    proxyExceptions =
      try container.decodeIfPresent(String.self, forKey: .proxyExceptions)
      ?? ProxySettings.defaultProxyExceptions
    externalPACCredentialReference = try container.decodeIfPresent(
      CredentialReference.self, forKey: .externalPACCredentialReference)
    gfwListCredentialReference = try container.decodeIfPresent(
      CredentialReference.self, forKey: .gfwListCredentialReference)
    gfwListURLConfigured =
      try container.decodeIfPresent(Bool.self, forKey: .gfwListURLConfigured) ?? false
    pacUserRules = try container.decodeIfPresent(String.self, forKey: .pacUserRules) ?? ""
    preferredMode =
      try container.decodeIfPresent(ProxyModeKind.self, forKey: .preferredMode) ?? .pac
    enabledModes =
      try container.decodeIfPresent([ProxyModeKind].self, forKey: .enabledModes)
      ?? ProxySettings.defaultEnabledModes.sorted { $0.rawValue < $1.rawValue }
  }
}

extension ProxySettingsRecord {
  fileprivate enum CodingKeys: String, CodingKey {
    case scopeKind, advertisedAddress, socksPort, httpProxyEnabled, httpPort, pacPort
    case udpRelayEnabled, timeoutSeconds, verboseLogging, proxyExceptions
    case externalPACCredentialReference, gfwListCredentialReference, gfwListURLConfigured
    case pacUserRules, preferredMode, enabledModes
  }
}
