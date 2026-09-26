import Foundation

/// #33 偏好存储。非敏感字段写入受保护的 JSON。GFWList URL 与 PAC 用户规则
/// 已随 issue #67 移除；未发布的 NG2 PAC 偏好不做迁移。
struct ProxySettingsFileStore: ProxySettingsStoring {
  let fileURL: URL
  let legacyListenFileURL: URL

  init(
    fileURL: URL = ProxySettingsFileStore.defaultFileURL(),
    legacyListenFileURL: URL = ListenSettingsFileStore.defaultFileURL()
  ) {
    self.fileURL = fileURL
    self.legacyListenFileURL = legacyListenFileURL
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
    do {
      let data = try Self.jsonEncoder.encode(record(from: settings))
      try AtomicFileWriter.write(data, to: fileURL)
    } catch let error as ProxySettingsStoreError {
      throw error
    } catch let error as AtomicFileWriter.WriteError {
      throw ProxySettingsStoreError.ioFailure(detail: String(describing: error))
    } catch {
      throw ProxySettingsStoreError.ioFailure(detail: String(describing: error))
    }
  }

  func reset() throws {
    let settingsSnapshot = try fileSnapshot(at: fileURL)
    let legacySnapshot = try fileSnapshot(at: legacyListenFileURL)
    do {
      try removeIfPresent(fileURL)
      try removeIfPresent(legacyListenFileURL)
    } catch {
      let filesRestored =
        restore(settingsSnapshot, at: fileURL)
        && restore(legacySnapshot, at: legacyListenFileURL)
      guard filesRestored else {
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

    return try validated(
      ProxySettings(
        listen: listen,
        timeoutSeconds: record.timeoutSeconds,
        verboseLogging: record.verboseLogging,
        proxyExceptions: record.proxyExceptions,
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
    record.timeoutSeconds = settings.timeoutSeconds
    record.verboseLogging = settings.verboseLogging
    record.proxyExceptions = settings.proxyExceptions
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

  private func asStoreError(_ error: Error) -> ProxySettingsStoreError {
    if let error = error as? ProxySettingsStoreError { return error }
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
  var timeoutSeconds: Int = 60
  var verboseLogging: Bool = false
  var proxyExceptions: String = ProxySettings.defaultProxyExceptions
  var preferredMode: ProxyModeKind = .rule
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
    timeoutSeconds = try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds) ?? 60
    verboseLogging = try container.decodeIfPresent(Bool.self, forKey: .verboseLogging) ?? false
    proxyExceptions =
      try container.decodeIfPresent(String.self, forKey: .proxyExceptions)
      ?? ProxySettings.defaultProxyExceptions
    // 旧 NG2 偏好里的 "pac" 等已删除值容错回落到规则模式（issue #67：
    // 未发布的 PAC 偏好不做迁移，但解码失败会把全部保留字段连坐丢掉）。
    if let rawMode = try container.decodeIfPresent(String.self, forKey: .preferredMode),
      let mode = ProxyModeKind(rawValue: rawMode)
    {
      preferredMode = mode
    } else {
      preferredMode = .rule
    }
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
    case scopeKind, advertisedAddress, socksPort, httpPort
    case timeoutSeconds, verboseLogging, proxyExceptions
    case preferredMode
    case ruleDefaultAction
    case agentEnabled, systemProxyEnabled
  }
}
