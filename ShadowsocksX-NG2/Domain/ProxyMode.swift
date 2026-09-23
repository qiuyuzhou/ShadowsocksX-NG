import Foundation

/// Persisted identity of a proxy mode. Unlike `ProxyMode`, this type does not
/// carry the URL of an external PAC, so it is safe to use in preferences and
/// mode-availability settings.
enum ProxyModeKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case pac
  case global
  case manual
  case externalPAC
}

/// The mutually exclusive ways in which 2.0 exposes the local proxy to macOS.
/// Hashable 供菜单栏模式选择的勾选态 Picker 使用（issue #31）。
enum ProxyMode: Codable, Equatable, Hashable, Sendable {
  case pac
  case global
  case manual
  case externalPAC(URL)

  private enum CodingKeys: String, CodingKey {
    case kind
    case url
  }

  private enum Kind: String, Codable {
    case pac
    case global
    case manual
    case externalPAC
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .pac:
      self = .pac
    case .global:
      self = .global
    case .manual:
      self = .manual
    case .externalPAC:
      self = .externalPAC(try container.decode(URL.self, forKey: .url))
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .pac:
      try container.encode(Kind.pac, forKey: .kind)
    case .global:
      try container.encode(Kind.global, forKey: .kind)
    case .manual:
      try container.encode(Kind.manual, forKey: .kind)
    case .externalPAC(let url):
      try container.encode(Kind.externalPAC, forKey: .kind)
      try container.encode(url, forKey: .url)
    }
  }

  var label: String {
    switch self {
    case .pac:
      "PAC"
    case .global:
      "全局"
    case .manual:
      "手动"
    case .externalPAC:
      "外部 PAC"
    }
  }

  var kind: ProxyModeKind {
    switch self {
    case .pac: .pac
    case .global: .global
    case .manual: .manual
    case .externalPAC: .externalPAC
    }
  }

  /// Returns every mode the current settings can support, in the product's
  /// stable selector order. Built-in modes are always available; external PAC
  /// is available only when its configured URL passes the existing validator.
  static func availableModes(for settings: ProxySettings) -> [ProxyMode] {
    let builtInModes: [ProxyMode] = [.pac, .global, .manual]
    guard !settings.externalPACURL.isEmpty,
      let url = URL(string: settings.externalPACURL),
      (try? validateExternalPACURL(url)) != nil
    else { return builtInModes }
    return builtInModes + [.externalPAC(url)]
  }

  /// Derives the only system-proxy state that this mode is allowed to own.
  /// `nil` means manual mode: restore the user's previous system settings and
  /// leave them under the user's control.
  func systemProxyConfiguration(
    for document: SslocalRuntimeDocument,
    exceptions: [String]? = nil
  ) throws -> SystemProxyConfiguration? {
    switch self {
    case .pac:
      guard let url = document.pac.publicURL else {
        throw ProxyModeError.invalidLocalPACURL
      }
      return SystemProxyConfiguration(target: .pac(url), exceptions: exceptions)
    case .global:
      guard (1...65535).contains(document.socksPort) else {
        throw ProxyModeError.invalidSOCKSPort(document.socksPort)
      }
      return SystemProxyConfiguration(
        target: .socks(host: "127.0.0.1", port: document.socksPort), exceptions: exceptions)
    case .manual:
      return nil
    case .externalPAC(let url):
      try Self.validateExternalPACURL(url)
      return SystemProxyConfiguration(target: .pac(url), exceptions: exceptions)
    }
  }

  static func validateExternalPACURL(_ url: URL) throws {
    guard let scheme = url.scheme?.lowercased() else {
      throw ProxyModeError.externalPACURLHasNoScheme
    }
    guard scheme == "http" || scheme == "https" else {
      throw ProxyModeError.unsupportedExternalPACScheme(scheme)
    }
    guard url.host != nil else {
      throw ProxyModeError.externalPACURLHasNoHost
    }
    guard url.user == nil && url.password == nil else {
      throw ProxyModeError.externalPACURLContainsCredentials
    }
    guard url.absoluteString.utf8.count <= 2048 else {
      throw ProxyModeError.externalPACURLTooLong
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
  case externalPACURLHasNoScheme
  case unsupportedExternalPACScheme(String)
  case externalPACURLHasNoHost
  case externalPACURLContainsCredentials
  case externalPACURLTooLong
}
