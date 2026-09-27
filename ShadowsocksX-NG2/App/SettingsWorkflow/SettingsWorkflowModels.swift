import Foundation

// MARK: - 平坦草稿（UI 形状，设置编辑态的唯一 source of truth）

/// UI 形状端口标识：设置页两个端口字段的稳定标识。端口行与建议空闲端口命令
/// 都用本标识；视图不导入探测层端点类型。
enum SettingsPortID: CaseIterable, Hashable, Sendable {
  case socks
  case http
}

/// The SOCKS5 and HTTP ports edited and saved together as one settings item.
struct SettingsPortDraft: Equatable, Sendable {
  var socksPort: Int
  var httpPort: Int

  func portValue(for id: SettingsPortID) -> Int {
    switch id {
    case .socks: socksPort
    case .http: httpPort
    }
  }

  mutating func setPortValue(_ value: Int, for id: SettingsPortID) {
    switch id {
    case .socks: socksPort = value
    case .http: httpPort = value
    }
  }
}

/// 平坦的 UI 形状编辑草稿：只包含由整体「保存设置」提交的字段。
/// 监听方式由独立编辑器单项提交，不进入此草稿。
struct SettingsDraft: Equatable, Sendable {
  var socksPort: Int
  var httpPort: Int
  var proxyExceptions: String

  func portValue(for id: SettingsPortID) -> Int {
    switch id {
    case .socks: socksPort
    case .http: httpPort
    }
  }

  mutating func setPortValue(_ value: Int, for id: SettingsPortID) {
    switch id {
    case .socks: socksPort = value
    case .http: httpPort = value
    }
  }
}

// MARK: - 按字段归位的校验问题

/// 字段标识（按字段归位查询）；端口问题用端口标识变体。
enum SettingsFieldID: Hashable, Sendable {
  case port(SettingsPortID)
}

/// 按字段归位的校验问题：每条保留 Domain 的 typed fact；文案由 App
/// presentation edge 派生。
enum SettingsFieldIssue: Hashable, Sendable {
  case port(SettingsPortID, error: ProxySettingsValidationError)

  var field: SettingsFieldID {
    switch self {
    case .port(let id, _): .port(id)
    }
  }

  var error: ProxySettingsValidationError {
    switch self {
    case .port(_, let error):
      error
    }
  }
}

// MARK: - 端口 field state

/// 端口占用的类型化事实（UI 形状）：文案与颜色由视图决定。
enum SettingsPortOccupancy: Equatable, Sendable {
  case free
  /// 端口不可绑定；占用进程名尽力解析（未知为 nil）。
  case occupied(occupier: String?)
  case unknown(detail: String)
}

/// 每个端口字段的 field state：两个端口行复用同一套呈现逻辑。
struct SettingsPortFieldState: Equatable, Sendable {
  let id: SettingsPortID
  /// 该端口当前草稿值。
  let draftValue: Int
  /// 类型化占用事实；`nil` = 尚未探测。
  let occupancy: SettingsPortOccupancy?
  /// 该端口的字段问题事实；文案由 presentation edge 派生。
  let issues: [SettingsFieldIssue]
  /// 是否为运行中端口例外（代理在跑且端口未变；保存其他设置不会触发冲突）。
  let isRuntimePortException: Bool
  /// 是否可建议空闲端口（被占用且不是运行中端口例外）。
  let canSuggestFreePort: Bool
}

// MARK: - 命令结果与拒绝原因

/// Typed reasons why a command cannot proceed. The workflow exposes facts,
/// not localized strings or a Boolean that makes validation and occupancy
/// failures indistinguishable.
enum SettingsCommandRejection: Equatable, Sendable {
  case inProgress
  case superseded
  case validation([SettingsFieldIssue])
  case occupied([SettingsPortID])
  case noFreePort(SettingsPortID)
}

enum SettingsPersistenceFailure: Error, Equatable, Sendable {
  case store(ProxySettingsStoreError)
  case unknown
}

/// Result returned by every discrete SettingsWorkflow command. Proxy runtime
/// status is presented by its owning status UI, not this settings interface.
enum SettingsCommandOutcome: Equatable, Sendable {
  case rejected(SettingsCommandRejection)
  case draftUpdated(port: SettingsPortID, value: Int)
  case reloaded
  case persisted
  case persistenceFailed(SettingsPersistenceFailure)
}

/// Settings workflow 的最后失败仍是 typed；workflow 不提前渲染句子。
enum SettingsWorkflowFailure: Error, Equatable, Sendable {
  case store(ProxySettingsStoreError)
  case unknown
}

enum ListenerModeSaveOutcome: Equatable, Sendable {
  case saved(unknownOccupancy: [SettingsPortID])
  case rejected(SettingsCommandRejection)
  case persistenceFailed(SettingsPersistenceFailure)
}
