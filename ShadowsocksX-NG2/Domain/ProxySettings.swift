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
  /// 规则模式子选项（issue #63）：未匹配默认动作，出厂「未匹配时代理」。
  var ruleDefaultAction: RuleDefaultAction
  /// 代理 agent 意图（issue #60）：首次运行默认开启；用户显式关闭的选择
  /// 持久化，GUI 重启后仍生效。
  var agentEnabled: Bool
  /// 系统代理意图（issue #60）：默认关闭；与 agent 意图相互独立，开关关闭
  /// 只恢复 NG2 持有的系统设置，不影响本地监听。
  var systemProxyEnabled: Bool

  init(
    listen: SslocalListenSettings = SslocalListenSettings(),
    timeoutSeconds: Int = 60,
    verboseLogging: Bool = false,
    proxyExceptions: String = ProxySettings.defaultProxyExceptions,
    gfwListURL: String = ProxySettings.defaultGFWListURL,
    pacUserRules: String = "",
    preferredMode: ProxyModeKind = .pac,
    ruleDefaultAction: RuleDefaultAction = .proxyWhenUnmatched,
    agentEnabled: Bool = true,
    systemProxyEnabled: Bool = false
  ) {
    self.listen = listen
    self.timeoutSeconds = timeoutSeconds
    self.verboseLogging = verboseLogging
    self.proxyExceptions = proxyExceptions
    self.gfwListURL = gfwListURL
    self.pacUserRules = pacUserRules
    self.preferredMode = preferredMode
    self.ruleDefaultAction = ruleDefaultAction
    self.agentEnabled = agentEnabled
    self.systemProxyEnabled = systemProxyEnabled
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
