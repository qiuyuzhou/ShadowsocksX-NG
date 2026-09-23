import Foundation

// MARK: - 平坦草稿（UI 形状，设置编辑态的唯一 source of truth）

/// UI 形状端口标识：设置页三个端口字段的稳定标识。端口行与建议空闲端口命令
/// 都用本标识；视图不导入探测层端点类型。
enum SettingsPortID: CaseIterable, Hashable, Sendable {
  case socks
  case http
  case pac
}

/// 平坦的 UI 形状编辑草稿：字段全部是 UI 原语。监听范围拆成布尔开关与公布
/// 地址文本两个字段，端口与超时保持整数；持久化的当前模式不在草稿中。
/// 与 Domain 快照的互转只在 `SettingsDraftAdapter`。
struct SettingsDraft: Equatable, Sendable {
  var isHostScope: Bool
  var advertisedAddress: String
  var socksPort: Int
  var httpProxyEnabled: Bool
  var httpPort: Int
  var pacPort: Int
  var udpRelayEnabled: Bool
  var timeoutSeconds: Int
  var verboseLogging: Bool
  var proxyExceptions: String
  var externalPACURL: String
  var gfwListURL: String
  var pacUserRules: String

  func portValue(for id: SettingsPortID) -> Int {
    switch id {
    case .socks: socksPort
    case .http: httpPort
    case .pac: pacPort
    }
  }

  mutating func setPortValue(_ value: Int, for id: SettingsPortID) {
    switch id {
    case .socks: socksPort = value
    case .http: httpPort = value
    case .pac: pacPort = value
    }
  }
}

// MARK: - 按字段归位的校验问题

/// 字段标识（按字段归位查询）；端口问题用端口标识变体。
enum SettingsFieldID: Hashable, Sendable {
  case advertisedAddress
  case port(SettingsPortID)
  case timeoutSeconds
  case externalPACURL
  case gfwListURL
}

/// 按字段归位的校验问题：每条保留 Domain 的 typed fact；文案由 App
/// presentation edge 派生。
enum SettingsFieldIssue: Equatable, Sendable {
  case port(SettingsPortID, error: ProxySettingsValidationError)
  case advertisedAddress(error: ProxySettingsValidationError)
  case timeoutSeconds(error: ProxySettingsValidationError)
  case externalPACURL(error: ProxySettingsValidationError)
  case gfwListURL(error: ProxySettingsValidationError)

  var field: SettingsFieldID {
    switch self {
    case .port(let id, _): .port(id)
    case .advertisedAddress: .advertisedAddress
    case .timeoutSeconds: .timeoutSeconds
    case .externalPACURL: .externalPACURL
    case .gfwListURL: .gfwListURL
    }
  }

  var error: ProxySettingsValidationError {
    switch self {
    case .port(_, let error), .advertisedAddress(let error), .timeoutSeconds(let error),
      .externalPACURL(let error), .gfwListURL(let error):
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

/// 每个端口字段的 field state：三个端口行复用同一套呈现逻辑。
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

// MARK: - 统一确认事实

/// 确认事实（统一种类）：seam 裁定动作是否需要确认及摘要内容；视图只持有
/// alert 呈现状态并把用户选择作为 typed command 发回。
enum SettingsConfirmation: Equatable, Sendable {
  /// PAC 地址将失效；仅携带前后端口事实。
  case pacInvalidation(previousPort: Int, nextPort: Int)
  /// 重置偏好；范围由这个 typed fact 固定，文案由 presentation edge 派生。
  case resetPreferences
}

/// Settings workflow 的最后失败仍是 typed；workflow 不提前渲染句子。
enum SettingsWorkflowFailure: Error, Equatable, Sendable {
  case store(ProxySettingsStoreError)
  case mode(ProxyModeError)
  case unknown
}
