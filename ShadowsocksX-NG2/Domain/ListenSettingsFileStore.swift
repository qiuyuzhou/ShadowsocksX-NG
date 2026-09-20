import Foundation

enum ListenSettingsStoreError: Error, Equatable {
  /// 文件存在但不是可接受的记录：JSON 损坏或字段缺失。
  case corrupt(detail: String)
  /// 记录可解码但端口配置无效（范围或互异校验失败）；点名全部原因。
  case invalidPorts([PortSettingError])
  /// 读取或写入时的文件系统错误。
  case ioFailure(detail: String)

  var presentedReason: String {
    switch self {
    case .corrupt:
      return "监听设置文件损坏"
    case .invalidPorts(let errors):
      return errors.map(\.presentedReason).joined(separator: "；")
    case .ioFailure:
      return "监听设置文件读取失败"
    }
  }
}

protocol ListenSettingsStoring {
  /// 文件缺失 → 出厂默认（出厂状态，不是改写用户配置）；损坏或无效 → 抛错。
  func load() throws -> SslocalListenSettings
  /// 保存前先做端口校验，被拒绝的保存不触碰已落盘文件。
  func save(_ settings: SslocalListenSettings) throws
}

/// 应用启动的监听设置恢复结果。`unreadableError` 非 nil 表示用户配置存在但
/// 不可读（损坏、无效或 I/O 失败），此时 `settings` 只是占位出厂默认——
/// 消费方不得静默以占位端口运行（D8「任何路径不静默改端口」），必须点名
/// 呈现并停止代理，等待用户修复。
struct RestoredListenSettings: Equatable {
  let settings: SslocalListenSettings
  let unreadableError: ListenSettingsStoreError?
}

/// 用户监听设置（端口、HTTP 启用、UDP、监听范围）的磁盘持久化，落盘
/// `~/Library/Application Support/ShadowsocksX-NG/listen-settings.json`。
/// 只承载用户显式确认过的配置；与 v2/ 运行时契约文件分离。监听范围只按
/// 原样保留，有效性由派生文档的读取侧校验兜底。
struct ListenSettingsFileStore: ListenSettingsStoring {
  private static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  let fileURL: URL

  static func defaultFileURL() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    return support.appendingPathComponent("ShadowsocksX-NG/listen-settings.json")
  }

  init(fileURL: URL = ListenSettingsFileStore.defaultFileURL()) {
    self.fileURL = fileURL
  }

  func load() throws -> SslocalListenSettings {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return SslocalListenSettings()
    }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw ListenSettingsStoreError.ioFailure(detail: String(describing: error))
    }
    let record: ListenSettingsRecord
    do {
      record = try JSONDecoder().decode(ListenSettingsRecord.self, from: data)
    } catch {
      throw ListenSettingsStoreError.corrupt(detail: String(describing: error))
    }
    let settings = Self.settings(from: record)
    let validationErrors = settings.portValidationErrors()
    guard validationErrors.isEmpty else {
      throw ListenSettingsStoreError.invalidPorts(validationErrors)
    }
    return settings
  }

  func save(_ settings: SslocalListenSettings) throws {
    let validationErrors = settings.portValidationErrors()
    guard validationErrors.isEmpty else {
      throw ListenSettingsStoreError.invalidPorts(validationErrors)
    }
    let data: Data
    do {
      data = try Self.jsonEncoder.encode(Self.record(from: settings))
    } catch {
      throw ListenSettingsStoreError.ioFailure(detail: String(describing: error))
    }
    do {
      try AtomicFileWriter.write(data, to: fileURL)
    } catch {
      throw ListenSettingsStoreError.ioFailure(detail: String(describing: error))
    }
  }

  /// 应用启动的恢复入口：文件缺失是出厂状态；用户配置不可读时记录事件并
  /// 携带点名错误返回占位出厂默认（消费方据此停止代理并呈现，不静默运行
  /// 在占位端口上；设置编辑呈现面在 #33）。
  static func restored() -> RestoredListenSettings {
    do {
      return RestoredListenSettings(settings: try Self().load(), unreadableError: nil)
    } catch let error as ListenSettingsStoreError {
      RuntimeLog.emit(.listenSettingsUnreadable(detail: String(describing: error)))
      return RestoredListenSettings(
        settings: SslocalListenSettings(), unreadableError: error)
    } catch {
      RuntimeLog.emit(.listenSettingsUnreadable(detail: String(describing: error)))
      return RestoredListenSettings(
        settings: SslocalListenSettings(),
        unreadableError: .ioFailure(detail: String(describing: error)))
    }
  }
}

/// 持久化记录只由本存储读写；测试以原始 JSON 夹具覆盖解码契约。
private struct ListenSettingsRecord: Codable, Equatable, Sendable {
  var scopeKind: ListenScopeKind = .loopback
  /// 主机态的对外公布地址；回环态为 nil。
  var advertisedAddress: String?
  var socksPort: Int = 1086
  var httpProxyEnabled: Bool = true
  var httpPort: Int = 1087
  var pacPort: Int = 1089
  var udpRelayEnabled: Bool = false
}

extension ListenSettingsFileStore {
  private static func record(from settings: SslocalListenSettings) -> ListenSettingsRecord {
    var record = ListenSettingsRecord()
    record.scopeKind = settings.scope.kind
    if case .host(let address) = settings.scope {
      record.advertisedAddress = address
    }
    record.socksPort = settings.socksPort
    record.httpProxyEnabled = settings.httpProxyEnabled
    record.httpPort = settings.httpPort
    record.pacPort = settings.pacPort
    record.udpRelayEnabled = settings.udpRelayEnabled
    return record
  }

  private static func settings(from record: ListenSettingsRecord) -> SslocalListenSettings {
    var settings = SslocalListenSettings()
    if record.scopeKind == .host, let address = record.advertisedAddress {
      settings.scope = .host(advertisedAddress: address)
    }
    settings.socksPort = record.socksPort
    settings.httpProxyEnabled = record.httpProxyEnabled
    settings.httpPort = record.httpPort
    settings.pacPort = record.pacPort
    settings.udpRelayEnabled = record.udpRelayEnabled
    return settings
  }
}
