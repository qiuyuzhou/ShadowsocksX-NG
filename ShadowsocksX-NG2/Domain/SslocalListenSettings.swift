import Foundation

/// 本地端点与单一监听范围的派生设置。HTTP 入站恒开启，与 SOCKS 共用同一
/// 范围；默认端口与 Legacy 隔离（11086/11087）。PAC 端点已随 issue #67 移除。
struct SslocalListenSettings: Equatable, Sendable {
  static let defaultSocksPort = 11086
  static let defaultHTTPPort = 11087

  var scope: ListenScope = .loopback
  var socksPort: Int = Self.defaultSocksPort
  var httpPort: Int = Self.defaultHTTPPort

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
}

/// Typed effective listener facts exposed by the runtime boundary. This is the
/// complete identity of the listeners that are actually intended to be bound:
/// scope carries both bind and advertised addresses, while the ports prevent a
/// same-port comparison from masquerading as a match.
struct RuntimeListenFacts: Equatable, Sendable {
  let scope: ListenScope
  let socksPort: Int
  let httpPort: Int

  init(listen: SslocalListenSettings) {
    self.init(
      scope: listen.scope,
      socksPort: listen.socksPort,
      httpPort: listen.httpPort)
  }

  init(
    scope: ListenScope,
    socksPort: Int,
    httpPort: Int
  ) {
    self.scope = scope
    self.socksPort = socksPort
    self.httpPort = httpPort
  }

  init(document: SslocalRuntimeDocument) {
    let scope: ListenScope
    switch document.listen.listenScope {
    case .loopback:
      scope = .loopback
    case .host:
      scope = .host(advertisedAddress: document.listen.advertisedAddress)
    }
    let socks = document.locals.first { $0.inboundProtocol == "socks" }
    let http = document.locals.first { $0.inboundProtocol == "http" }
    self.init(
      scope: scope,
      socksPort: socks?.localPort ?? 0,
      httpPort: http?.localPort ?? SslocalListenSettings.defaultHTTPPort)
  }

  var bindAddress: String { scope.bindAddress }
  var advertisedAddress: String { scope.advertisedAddress }
}

/// 监听指纹（spec #21 D5/D7）：服务器列表变化可热重载；任一本地入站、
/// ACL 内容/路径/摘要或 verbose（决定 spawn 时的 RUST_LOG）变化都必须由
/// wrapper 完整重启 sslocal。
struct SslocalListenFingerprint: Equatable, Sendable {
  let locals: [SslocalLocalDocument]
  let acl: ProxyACLDocument?
  let verbose: Bool
}
