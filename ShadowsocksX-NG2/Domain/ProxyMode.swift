import Foundation

/// Persisted identity of a proxy mode.
enum ProxyModeKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case pac
  case global
  case direct
}

/// The mutually exclusive ways in which 2.0 exposes the local proxy to macOS.
/// Hashable 供菜单栏模式选择的勾选态 Picker 使用（issue #31）。
enum ProxyMode: Codable, Equatable, Hashable, Sendable {
  case pac
  case global
  case direct

  private enum CodingKeys: String, CodingKey {
    case kind
  }

  private enum Kind: String, Codable {
    case pac
    case global
    case direct
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .pac:
      self = .pac
    case .global:
      self = .global
    case .direct:
      self = .direct
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pac:
      try container.encode(Kind.pac, forKey: .kind)
    case .global:
      try container.encode(Kind.global, forKey: .kind)
    case .direct:
      try container.encode(Kind.direct, forKey: .kind)
    }
  }

  var label: String {
    switch self {
    case .pac:
      "PAC"
    case .global:
      "全局"
    case .direct:
      "直连"
    }
  }

  var kind: ProxyModeKind {
    switch self {
    case .pac: .pac
    case .global: .global
    case .direct: .direct
    }
  }

  /// Returns every mode supported by the product in stable selector order.
  static var availableModes: [ProxyMode] { [.pac, .global, .direct] }

  /// Derives the only system-proxy state that this mode is allowed to own.
  func systemProxyConfiguration(
    for document: SslocalRuntimeDocument,
    exceptions: [String]? = nil
  ) throws -> SystemProxyConfiguration {
    switch self {
    case .pac:
      guard let url = document.pac.publicURL else {
        throw ProxyModeError.invalidLocalPACURL
      }
      return SystemProxyConfiguration(target: .pac(url), exceptions: exceptions)
    case .global, .direct:
      guard (1...65535).contains(document.socksPort) else {
        throw ProxyModeError.invalidSOCKSPort(document.socksPort)
      }
      return SystemProxyConfiguration(
        target: .socks(host: "127.0.0.1", port: document.socksPort),
        exceptions: FixedLocalProxyRanges.systemProxyExceptions(including: exceptions))
    }
  }
}

/// The part of the system proxy dictionary that 2.0 intentionally controls.
struct SystemProxyConfiguration: Equatable, Sendable {
  enum Target: Equatable, Sendable {
    case pac(URL)
    case socks(host: String, port: Int)
  }

  let target: Target
  /// `nil` preserves the user's original ExceptionsList. A non-nil value is
  /// explicitly owned by the app and is projected on every activation.
  let exceptions: [String]?

  init(target: Target, exceptions: [String]? = nil) {
    self.target = target
    self.exceptions = exceptions
  }
}

enum ProxyModeError: Error, Equatable, Sendable {
  case invalidLocalPACURL
  case invalidSOCKSPort(Int)
}
