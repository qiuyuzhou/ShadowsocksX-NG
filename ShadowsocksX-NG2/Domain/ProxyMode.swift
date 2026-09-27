import Foundation

/// Persisted identity of a proxy mode. PAC is gone (issue #67): the product
/// exposes rule / global / direct only.
enum ProxyModeKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case rule
  case global
  case direct
}

/// The mutually exclusive ways in which 2.0 exposes the local proxy to macOS.
/// Hashable 供菜单栏模式选择的勾选态 Picker 使用（issue #31）。
/// 规则模式（issue #63）另持久化 `RuleDefaultAction` 子选项。
enum ProxyMode: Codable, Equatable, Hashable, Sendable {
  case rule
  case global
  case direct

  private enum CodingKeys: String, CodingKey {
    case kind
  }

  private enum Kind: String, Codable {
    case rule
    case global
    case direct
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .rule:
      self = .rule
    case .global:
      self = .global
    case .direct:
      self = .direct
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .rule:
      try container.encode(Kind.rule, forKey: .kind)
    case .global:
      try container.encode(Kind.global, forKey: .kind)
    case .direct:
      try container.encode(Kind.direct, forKey: .kind)
    }
  }

  var label: String {
    switch self {
    case .rule:
      "规则"
    case .global:
      "全局"
    case .direct:
      "直连"
    }
  }

  var kind: ProxyModeKind {
    switch self {
    case .rule: .rule
    case .global: .global
    case .direct: .direct
    }
  }

  /// Returns every mode supported by the product in stable selector order.
  static var availableModes: [ProxyMode] { [.rule, .global, .direct] }

  /// Derives the only system-proxy state that this mode is allowed to own.
  /// All three modes are projected as the local SOCKS and HTTP inbounds
  /// (issue #59/#67)：SOCKS 之外，系统 HTTP/HTTPS 代理指向恒开启的 HTTP 入站。
  func systemProxyConfiguration(
    for document: SslocalRuntimeDocument,
    exceptions: [String]? = nil
  ) throws -> SystemProxyConfiguration {
    guard ProxyPortRange.valid.contains(document.socksPort) else {
      throw ProxyModeError.invalidSOCKSPort(document.socksPort)
    }
    guard ProxyPortRange.valid.contains(document.httpPort) else {
      throw ProxyModeError.invalidHTTPPort(document.httpPort)
    }
    return SystemProxyConfiguration(
      socks: .init(host: "127.0.0.1", port: document.socksPort),
      http: .init(host: "127.0.0.1", port: document.httpPort),
      exceptions: FixedLocalProxyRanges.systemProxyExceptions(including: exceptions))
  }
}

/// The part of the system proxy dictionary that 2.0 intentionally controls.
/// SOCKS 与 HTTP/HTTPS 两个协议族同时写入，各指向 sslocal 的对应本地入站；
/// HTTPS 走 HTTP 入站的 CONNECT 代理，与 SOCKS 共用同一实例。
struct SystemProxyConfiguration: Equatable, Sendable {
  /// 一个系统代理协议族指向的本地端点。
  struct Endpoint: Equatable, Sendable {
    let host: String
    let port: Int
  }

  let socks: Endpoint
  /// 系统 HTTP 与 HTTPS 代理共同指向的 HTTP 入站端点。
  let http: Endpoint
  /// `nil` preserves the user's original ExceptionsList. A non-nil value is
  /// explicitly owned by the app and is projected on every activation.
  let exceptions: [String]?

  init(socks: Endpoint, http: Endpoint, exceptions: [String]? = nil) {
    self.socks = socks
    self.http = http
    self.exceptions = exceptions
  }
}

enum ProxyModeError: Error, Equatable, Sendable {
  case invalidSOCKSPort(Int)
  case invalidHTTPPort(Int)
}
