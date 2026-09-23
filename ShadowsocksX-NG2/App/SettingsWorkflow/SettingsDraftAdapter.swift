import Foundation

/// 写入侧窄 seam（issue #44）：设置工作流只依赖已提交快照、代理是否在跑与
/// 两个提交入口。生产实现是 `ProxyRuntimeController` 的薄扩展；测试注入
/// fake。Domain 快照类型只出现在本缝与 `SettingsDraftAdapter`。读取侧是
/// 运行时控制器的主 actor 状态，本缝随之主 actor 绑定。
@MainActor
protocol SettingsCommitting: AnyObject {
  var committedSettings: ProxySettings { get }
  var isProxyRunning: Bool { get }
  func updateSettings(_ proposed: ProxySettings) async throws
  func resetPreferences() async throws
}

extension ProxyRuntimeController: SettingsCommitting {
  var committedSettings: ProxySettings { settings }
  var isProxyRunning: Bool { state.isOn }
}

/// 平坦草稿与 Domain 快照的单一 adapter（story 45）：字段清单变化只改此处。
/// 校验错误到字段问题、UI 端口标识到端点类型的映射同属字段清单，一并收在
/// 本文件；Domain 快照类型不出现在 UI-facing interface。
enum SettingsDraftAdapter {
  /// 已提交快照 → 平坦草稿。主机地址态的公布地址只在局域网模式有意义，
  /// 仅本机模式回到空文本。
  static func draft(from settings: ProxySettings) -> SettingsDraft {
    let isHostScope: Bool
    let advertisedAddress: String
    switch settings.listen.scope {
    case .loopback:
      isHostScope = false
      advertisedAddress = ""
    case .host(let address):
      isHostScope = true
      advertisedAddress = address
    }
    return SettingsDraft(
      isHostScope: isHostScope,
      advertisedAddress: advertisedAddress,
      socksPort: settings.listen.socksPort,
      httpProxyEnabled: settings.listen.httpProxyEnabled,
      httpPort: settings.listen.httpPort,
      pacPort: settings.listen.pacPort,
      udpRelayEnabled: settings.listen.udpRelayEnabled,
      timeoutSeconds: settings.timeoutSeconds,
      verboseLogging: settings.verboseLogging,
      proxyExceptions: settings.proxyExceptions,
      gfwListURL: settings.gfwListURL,
      pacUserRules: settings.pacUserRules)
  }

  /// 平坦草稿 → Domain 快照。持久化的当前模式不在草稿中，从 `base` 保留。
  static func settings(
    from draft: SettingsDraft, preservingModeOf base: ProxySettings
  ) -> ProxySettings {
    var listen = SslocalListenSettings()
    listen.scope =
      draft.isHostScope ? .host(advertisedAddress: draft.advertisedAddress) : .loopback
    listen.socksPort = draft.socksPort
    listen.httpProxyEnabled = draft.httpProxyEnabled
    listen.httpPort = draft.httpPort
    listen.pacPort = draft.pacPort
    listen.udpRelayEnabled = draft.udpRelayEnabled
    return ProxySettings(
      listen: listen,
      timeoutSeconds: draft.timeoutSeconds,
      verboseLogging: draft.verboseLogging,
      proxyExceptions: draft.proxyExceptions,
      gfwListURL: draft.gfwListURL,
      pacUserRules: draft.pacUserRules,
      preferredMode: base.preferredMode)
  }

  /// UI 形状端口标识 → 端点类型（module 内部复用 Domain 端口语义）。
  static func endpoint(for id: SettingsPortID) -> ProxyEndpointKind {
    switch id {
    case .socks: .socks
    case .http: .http
    case .pac: .pac
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
      case .invalidTimeout:
        return [.timeoutSeconds(error: error)]
      case .invalidHostAddress:
        return [.advertisedAddress(error: error)]
      case .invalidGFWListURL:
        return [.gfwListURL(error: error)]
      }
    }
  }

  private static func portID(for endpoint: ProxyEndpointKind) -> SettingsPortID {
    switch endpoint {
    case .socks: .socks
    case .http: .http
    case .pac: .pac
    }
  }
}

extension SettingsPortOccupancy {
  /// 探测层判定 → UI 形状事实。
  init(_ occupancy: PortOccupancy) {
    switch occupancy {
    case .free:
      self = .free
    case .occupied(let occupier):
      self = .occupied(occupier: occupier)
    case .unknown(let detail):
      self = .unknown(detail: detail)
    }
  }
}
