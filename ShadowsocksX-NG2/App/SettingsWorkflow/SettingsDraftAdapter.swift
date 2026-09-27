import Foundation

/// 写入侧窄 seam（issue #48）：设置工作流只依赖已提交快照、当前 runtime 的
/// typed listener facts 与提交入口。生产实现是 `ProxyRuntimeController`
/// 的薄扩展；测试注入 fake。Domain 快照类型只出现在本缝与 adapter。读取侧是
/// 运行时控制器的主 actor 状态，本缝随之主 actor 绑定。
@MainActor
protocol SettingsCommitting: AnyObject {
  var committedSettings: ProxySettings { get }
  var runtimeListenFacts: RuntimeListenFacts? { get }
  var runtimeListenerProcessID: Int32? { get }
  func updateSettings(_ proposed: ProxySettings) async throws
  func updateListenerMode(_ mode: ListenerMode) async throws
}

extension ProxyRuntimeController: SettingsCommitting {
  var committedSettings: ProxySettings { settings }
  var runtimeListenFacts: RuntimeListenFacts? { effectiveRuntimeListenFacts }
  var runtimeListenerProcessID: Int32? { effectiveRuntimeListenerProcessID }

  func updateListenerMode(_ mode: ListenerMode) async throws {
    var proposed = settings
    proposed.listen.listenerMode = mode
    try await updateSettings(proposed)
  }
}

/// 平坦草稿与 Domain 快照的单一 adapter（story 45）：字段清单变化只改此处。
/// 校验错误到字段问题、UI 端口标识到端点类型的映射同属字段清单，一并收在
/// 本文件；Domain 快照类型不出现在 UI-facing interface。
enum SettingsDraftAdapter {
  /// 已提交快照 → 整体设置草稿；独立保存的监听方式不会进入此草稿。
  static func draft(from settings: ProxySettings) -> SettingsDraft {
    return SettingsDraft(
      socksPort: settings.listen.socksPort,
      httpPort: settings.listen.httpPort,
      proxyExceptions: settings.proxyExceptions)
  }

  /// 平坦草稿 → Domain 快照。监听方式与其它未编辑偏好从 `base` 保留。
  static func settings(
    from draft: SettingsDraft, preservingUneditedFieldsOf base: ProxySettings
  ) -> ProxySettings {
    var settings = base
    settings.listen.socksPort = draft.socksPort
    settings.listen.httpPort = draft.httpPort
    settings.proxyExceptions = draft.proxyExceptions
    return settings
  }

  /// 平坦草稿对应的完整有效监听身份。占用探测和 runtime 例外判断共用此
  /// adapter，避免在 workflow 内复制 scope/address/endpoint 字段清单。
  static func listenFacts(
    from draft: SettingsDraft, preservingModeOf base: ProxySettings
  ) -> RuntimeListenFacts {
    var listen = base.listen
    listen.socksPort = draft.socksPort
    listen.httpPort = draft.httpPort
    return RuntimeListenFacts(listen: listen)
  }

  /// UI 形状端口标识 → 端点类型（module 内部复用 Domain 端口语义）。
  static func endpoint(for id: SettingsPortID) -> ProxyEndpointKind {
    switch id {
    case .socks: .socks
    case .http: .http
    }
  }

  /// Domain 点名校验错误 → 按字段归位的问题；点名文案沿用既有错误属性。
  /// 端口互异涉及两个端点，两侧端口各归位一条，用户只改有错的那个输入。
  static func fieldIssues(from errors: [ProxySettingsValidationError]) -> [SettingsFieldIssue] {
    errors.flatMap { error -> [SettingsFieldIssue] in
      switch error {
      case .portOutOfRange(let endpoint, _):
        return [.port(portID(for: endpoint), error: error)]
      case .duplicatePort(let endpoint, let otherEndpoint, _):
        return [
          .port(portID(for: endpoint), error: error),
          .port(portID(for: otherEndpoint), error: error),
        ]
      }
    }
  }

  private static func portID(for endpoint: ProxyEndpointKind) -> SettingsPortID {
    switch endpoint {
    case .socks: .socks
    case .http: .http
    }
  }
}

extension SettingsPortOccupancy {
  /// 探测层判定 → UI 形状事实。
  init(_ occupancy: PortOccupancy) {
    switch occupancy {
    case .free:
      self = .free
    case .occupied(let facts):
      self = .occupied(occupier: facts.occupier)
    case .unknown(let detail):
      self = .unknown(detail: detail)
    }
  }
}
