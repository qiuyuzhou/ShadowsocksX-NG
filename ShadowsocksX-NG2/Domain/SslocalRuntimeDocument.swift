import Darwin
import Foundation

/// 用户可见监听范围。主机地址态把对外公布地址与通配绑定地址绑定在同一个值
/// 对象中，避免监听身份与实际绑定范围各自漂移（spec #21 D7，issue #28）。
enum ListenScope: Equatable, Sendable {
  case loopback
  case host(advertisedAddress: String)

  var kind: ListenScopeKind {
    switch self {
    case .loopback: .loopback
    case .host: .host
    }
  }

  var bindAddress: String {
    switch self {
    case .loopback: "127.0.0.1"
    case .host: "0.0.0.0"
    }
  }

  var advertisedAddress: String {
    switch self {
    case .loopback: "127.0.0.1"
    case .host(let address): address
    }
  }
}

enum ListenScopeKind: String, Codable, Equatable, Sendable {
  case loopback
  case host
}

/// `sslocal` 的一个本地入站。上游 v1.25.0 通过 `locals[]` 同时承载 SOCKS5
/// 与 HTTP；HTTP 直接由 shadowsocks-rust 提供，不经过 Legacy Privoxy。
struct SslocalLocalDocument: Codable, Equatable, Sendable {
  let inboundProtocol: String
  let localAddress: String
  let localPort: Int
  let mode: String

  enum CodingKeys: String, CodingKey {
    case mode
    case inboundProtocol = "protocol"
    case localAddress = "local_address"
    case localPort = "local_port"
  }
}

/// wrapper 自有的监听身份扩展（issue #67 取代已删除的 PAC 扩展）。字段收在
/// `x_shadowsocksx_ng_listen` 下，上游 sslocal 会忽略该扩展；wrapper 与 GUI
/// 仍从同一原子文件读取同一份事实。verbose 决定 sslocal 的 RUST_LOG 级别。
struct RuntimeListenDocument: Codable, Equatable, Sendable {
  let listenScope: ListenScopeKind
  let bindAddress: String
  let advertisedAddress: String
  let verbose: Bool

  enum CodingKeys: String, CodingKey {
    case listenScope = "listen_scope"
    case bindAddress = "bind_address"
    case advertisedAddress = "advertised_address"
    case verbose
  }

  init(
    listenScope: ListenScopeKind,
    bindAddress: String,
    advertisedAddress: String,
    verbose: Bool = false
  ) {
    self.listenScope = listenScope
    self.bindAddress = bindAddress
    self.advertisedAddress = advertisedAddress
    self.verbose = verbose
  }
}

/// sslocal 运行时文档（spec #21 D5/D7）：激活派生出的完整 JSON 契约文档。
/// 密码与插件参数已在此解析为明文——只供运行时落盘，永不入日志。
struct SslocalRuntimeDocument: Codable, Equatable, Sendable {
  let servers: [SslocalServerDocument]
  let locals: [SslocalLocalDocument]
  let listen: RuntimeListenDocument
  let timeout: Int
  /// Upstream sslocal ACL file path. The wrapper-owned extension carries the
  /// matching content and digest so both inbounds use the same validated file.
  let aclFilePath: String?
  let aclRuntime: ProxyACLDocument?

  enum CodingKeys: String, CodingKey {
    case servers, locals, timeout
    case aclFilePath = "acl"
    case aclRuntime = "x_shadowsocksx_ng_acl"
    case listen = "x_shadowsocksx_ng_listen"
  }

  init(
    servers: [SslocalServerDocument],
    listen: SslocalListenSettings,
    timeout: Int = 60,
    verbose: Bool = false,
    acl: ProxyACLDocument? = nil
  ) {
    self.servers = servers
    locals = listen.locals
    self.listen = RuntimeListenDocument(
      listenScope: listen.scope.kind,
      bindAddress: listen.bindAddress,
      advertisedAddress: listen.advertisedAddress,
      verbose: verbose)
    self.timeout = timeout
    aclFilePath = acl?.path
    aclRuntime = acl
  }

  private init(
    servers: [SslocalServerDocument],
    locals: [SslocalLocalDocument],
    listen: RuntimeListenDocument,
    timeout: Int,
    acl: ProxyACLDocument?
  ) {
    self.servers = servers
    self.locals = locals
    self.listen = listen
    self.timeout = timeout
    aclFilePath = acl?.path
    aclRuntime = acl
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    servers = try container.decode([SslocalServerDocument].self, forKey: .servers)
    locals = try container.decode([SslocalLocalDocument].self, forKey: .locals)
    listen = try container.decode(RuntimeListenDocument.self, forKey: .listen)
    timeout = try container.decodeIfPresent(Int.self, forKey: .timeout) ?? 60
    aclFilePath = try container.decodeIfPresent(String.self, forKey: .aclFilePath)
    aclRuntime = try container.decodeIfPresent(ProxyACLDocument.self, forKey: .aclRuntime)
  }

  func jsonData() throws -> Data {
    try Self.jsonEncoder.encode(self)
  }

  var deploymentSHA256: String? {
    guard let data = try? jsonData() else { return nil }
    return ProxyACLDocument.digest(data)
  }

  func replacingACL(_ acl: ProxyACLDocument?) -> SslocalRuntimeDocument {
    SslocalRuntimeDocument(
      servers: servers,
      locals: locals,
      listen: listen,
      timeout: timeout,
      acl: acl)
  }

  private static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()
}

/// 上游 `servers[]` 条目。id/remarks 携带叶子身份与显示名，供上游稳定标识；
/// 插件字段在无插件时整体省略（D10）。
struct SslocalServerDocument: Codable, Equatable, Sendable {
  let id: String
  let remarks: String
  let server: String
  let serverPort: Int
  let password: String
  let method: String
  let plugin: String?
  let pluginOpts: String?

  enum CodingKeys: String, CodingKey {
    case id, remarks, server
    case serverPort = "server_port"
    case password, method, plugin
    case pluginOpts = "plugin_opts"
  }
}

extension SslocalLocalDocument {
  /// 探测用主机名：通配绑定地址按回环探测（wrapper 监听判定与 GUI 健康门
  /// 共用口径，issue #38）。
  var probeHost: String {
    localAddress == "0.0.0.0" ? "127.0.0.1" : localAddress
  }
}

extension SslocalRuntimeDocument {
  static func decodeValidated(_ data: Data) -> SslocalRuntimeDocument? {
    guard
      let document = try? JSONDecoder().decode(SslocalRuntimeDocument.self, from: data),
      document.isWellFormed
    else { return nil }
    return document
  }

  var listenFingerprint: SslocalListenFingerprint {
    SslocalListenFingerprint(locals: locals, acl: aclRuntime, verbose: listen.verbose)
  }

  var socksLocal: SslocalLocalDocument? {
    locals.first { $0.inboundProtocol == "socks" }
  }

  var socksAddress: String { socksLocal?.localAddress ?? "" }
  var socksPort: Int { socksLocal?.localPort ?? 0 }
  var socksMode: String { socksLocal?.mode ?? "" }

  /// wrapper 读取侧防御校验：端口、协议与共享范围必须一致；无效文件按 D5
  /// 停止并清理，不能交给 KeepAlive 无限重放。空 `servers` 合法（issue #60）：
  /// 无活动目标时 agent 以空服务器列表提供本地监听；上游 sslocal v1.25.0
  /// 接受空 servers 并照常绑定本地入站。
  var isWellFormed: Bool {
    guard
      (1...86_400).contains(timeout),
      !listen.advertisedAddress.isEmpty
    else { return false }

    guard
      (aclFilePath == nil) == (aclRuntime == nil),
      aclRuntime.map({ $0.isWellFormed && $0.path == aclFilePath }) ?? true
    else { return false }

    let expectedBind = listen.listenScope == .loopback ? "127.0.0.1" : "0.0.0.0"
    guard listen.bindAddress == expectedBind else {
      return false
    }
    switch listen.listenScope {
    case .loopback:
      guard listen.advertisedAddress == "127.0.0.1" else { return false }
    case .host:
      guard
        isIPv4Address(listen.advertisedAddress),
        listen.advertisedAddress != "0.0.0.0",
        listen.advertisedAddress != "127.0.0.1"
      else {
        return false
      }
    }

    let socks = locals.filter { $0.inboundProtocol == "socks" }
    let http = locals.filter { $0.inboundProtocol == "http" }
    guard socks.count == 1, http.count <= 1, locals.count == socks.count + http.count else {
      return false
    }
    guard socks[0].mode == "tcp_and_udp" else { return false }
    guard http.allSatisfy({ $0.mode == "tcp_only" }) else { return false }

    let localPorts = locals.map(\.localPort)
    guard Set(localPorts).count == localPorts.count else { return false }
    guard
      locals.allSatisfy({ local in
        let expectedMode = local.inboundProtocol == "socks" ? "tcp_and_udp" : "tcp_only"
        return local.localAddress == expectedBind
          && (1...65535).contains(local.localPort)
          && local.mode == expectedMode
      })
    else { return false }

    return servers.allSatisfy { server in
      (1...65535).contains(server.serverPort)
        && !server.id.isEmpty
        && !server.server.isEmpty
        && !server.method.isEmpty
    }
  }
}

private func isIPv4Address(_ value: String) -> Bool {
  var address = in_addr()
  return value.withCString { inet_pton(AF_INET, $0, &address) == 1 }
}
