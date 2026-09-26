import Foundation

/// 三个本地端点与单一监听范围的派生设置。HTTP 入站恒开启，与 SOCKS、PAC
/// 共用同一范围；默认端口与 Legacy 隔离（11086/11087/11089）。
struct SslocalListenSettings: Equatable, Sendable {
  static let defaultSocksPort = 11086
  static let defaultHTTPPort = 11087
  static let defaultPACPort = 11089

  var scope: ListenScope = .loopback
  var socksPort: Int = Self.defaultSocksPort
  var httpPort: Int = Self.defaultHTTPPort
  var pacPort: Int = Self.defaultPACPort

  var bindAddress: String { scope.bindAddress }
  var advertisedAddress: String { scope.advertisedAddress }
  var mode: String { "tcp_and_udp" }

  var locals: [SslocalLocalDocument] {
    [
      SslocalLocalDocument(
        inboundProtocol: "socks",
        localAddress: bindAddress,
        localPort: socksPort,
        mode: mode),
      SslocalLocalDocument(
        inboundProtocol: "http",
        localAddress: bindAddress,
        localPort: httpPort,
        mode: "tcp_only"),
    ]
  }

  var pac: PACRuntimeDocument {
    pac(userRules: "", verbose: false)
  }

  func pac(userRules: String, verbose: Bool) -> PACRuntimeDocument {
    PACRuntimeDocument(
      listenScope: scope.kind,
      bindAddress: bindAddress,
      advertisedAddress: advertisedAddress,
      port: pacPort,
      socksPort: socksPort,
      endpointPath: PACRuntimeDocument.versionedEndpointPath,
      userRules: userRules,
      verbose: verbose)
  }
}

/// Typed effective listener facts exposed by the runtime boundary. This is the
/// complete identity of the listeners that are actually intended to be bound:
/// scope carries both bind and advertised addresses, while the ports prevent a
/// same-port comparison from masquerading as a match.
struct RuntimeListenFacts: Equatable, Sendable {
  let scope: ListenScope
  let socksPort: Int
  let httpPort: Int
  let pacPort: Int

  init(listen: SslocalListenSettings) {
    self.init(
      scope: listen.scope,
      socksPort: listen.socksPort,
      httpPort: listen.httpPort,
      pacPort: listen.pacPort)
  }

  init(
    scope: ListenScope,
    socksPort: Int,
    httpPort: Int,
    pacPort: Int
  ) {
    self.scope = scope
    self.socksPort = socksPort
    self.httpPort = httpPort
    self.pacPort = pacPort
  }

  init(document: SslocalRuntimeDocument) {
    let scope: ListenScope
    switch document.pac.listenScope {
    case .loopback:
      scope = .loopback
    case .host:
      scope = .host(advertisedAddress: document.pac.advertisedAddress)
    }
    let socks = document.locals.first { $0.inboundProtocol == "socks" }
    let http = document.locals.first { $0.inboundProtocol == "http" }
    self.init(
      scope: scope,
      socksPort: socks?.localPort ?? document.pac.socksPort,
      httpPort: http?.localPort ?? SslocalListenSettings.defaultHTTPPort,
      pacPort: document.pac.port)
  }

  var bindAddress: String { scope.bindAddress }
  var advertisedAddress: String { scope.advertisedAddress }
}

/// 监听指纹（spec #21 D5/D7）：服务器列表变化可热重载；任一本地入站、PAC
/// endpoint 或 ACL 内容/路径/摘要变化都必须由 wrapper 完整重启 sslocal。
struct SslocalListenFingerprint: Equatable, Sendable {
  let locals: [SslocalLocalDocument]
  let pac: PACRuntimeDocument
  let acl: ProxyACLDocument?
}
