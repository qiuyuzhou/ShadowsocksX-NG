import Darwin
import Foundation

/// 用户可见监听范围。主机地址态把对外公布地址与通配绑定地址绑定在同一个值
/// 对象中，避免 PAC 内容与实际监听范围各自漂移（spec #21 D7，issue #28）。
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

/// wrapper 自有的 PAC 契约。字段收在 `x_shadowsocksx_ng_pac` 下，上游
/// sslocal 会忽略该扩展；wrapper 与 GUI 仍从同一原子文件读取同一份事实。
struct PACRuntimeDocument: Codable, Equatable, Sendable {
  /// #28 固定的是 API 版本路由；逐 snapshot generation URL 与 ownership/cache
  /// 事务属于系统代理工单 #29，不能在此提前改变对外 URL 契约。
  static let versionedEndpointPath = "/v1/proxy.pac"

  let listenScope: ListenScopeKind
  let bindAddress: String
  let advertisedAddress: String
  let port: Int
  let socksPort: Int
  let endpointPath: String
  let userRules: String
  let verbose: Bool

  enum CodingKeys: String, CodingKey {
    case port
    case listenScope = "listen_scope"
    case bindAddress = "bind_address"
    case advertisedAddress = "advertised_address"
    case socksPort = "socks_port"
    case endpointPath = "endpoint_path"
    case userRules = "user_rules"
    case verbose
  }

  init(
    listenScope: ListenScopeKind,
    bindAddress: String,
    advertisedAddress: String,
    port: Int,
    socksPort: Int,
    endpointPath: String,
    userRules: String = "",
    verbose: Bool = false
  ) {
    self.listenScope = listenScope
    self.bindAddress = bindAddress
    self.advertisedAddress = advertisedAddress
    self.port = port
    self.socksPort = socksPort
    self.endpointPath = endpointPath
    self.userRules = userRules
    self.verbose = verbose
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    listenScope = try container.decode(ListenScopeKind.self, forKey: .listenScope)
    bindAddress = try container.decode(String.self, forKey: .bindAddress)
    advertisedAddress = try container.decode(String.self, forKey: .advertisedAddress)
    port = try container.decode(Int.self, forKey: .port)
    socksPort = try container.decode(Int.self, forKey: .socksPort)
    endpointPath = try container.decode(String.self, forKey: .endpointPath)
    userRules = try container.decodeIfPresent(String.self, forKey: .userRules) ?? ""
    verbose = try container.decodeIfPresent(Bool.self, forKey: .verbose) ?? false
  }

  var javaScript: String {
    let chain =
      "SOCKS5 \(advertisedAddress):\(socksPort); SOCKS \(advertisedAddress):\(socksPort); DIRECT"
    let directSuffixes = PACRuleSet.directHostSuffixes(from: userRules)
    guard !directSuffixes.isEmpty else {
      return "function FindProxyForURL(url, host) { return \"\(chain)\"; }\n"
    }
    var lines = ["function FindProxyForURL(url, host) {"]
    lines.append(
      contentsOf: directSuffixes.map { suffix in
        "  if (dnsDomainIs(host, \"\(suffix)\")) return \"DIRECT\";"
      })
    lines.append("  return \"\(chain)\";")
    lines.append("}\n")
    return lines.joined(separator: "\n")
  }

  /// 给用户复制/系统代理写入的 URL；主机态必须使用可路由的 LAN 地址。
  var publicURL: URL? {
    makeURL(host: advertisedAddress)
  }

  /// GUI 健康检查固定走本机回环，避免把防火墙本机执法盲区误写成远端验证。
  var healthURL: URL? {
    makeURL(host: "127.0.0.1")
  }

  private func makeURL(host: String) -> URL? {
    var components = URLComponents()
    components.scheme = "http"
    components.host = host
    components.port = port
    components.path = endpointPath
    return components.url
  }
}

/// sslocal 运行时文档（spec #21 D5/D7）：激活派生出的完整 JSON 契约文档。
/// 密码与插件参数已在此解析为明文——只供运行时落盘，永不入日志。
struct SslocalRuntimeDocument: Codable, Equatable, Sendable {
  let servers: [SslocalServerDocument]
  let locals: [SslocalLocalDocument]
  let pac: PACRuntimeDocument
  let timeout: Int

  enum CodingKeys: String, CodingKey {
    case servers, locals, timeout
    case pac = "x_shadowsocksx_ng_pac"
  }

  init(
    servers: [SslocalServerDocument],
    listen: SslocalListenSettings,
    timeout: Int = 60,
    verbose: Bool = false,
    pacUserRules: String = ""
  ) {
    self.servers = servers
    locals = listen.locals
    pac = listen.pac(userRules: pacUserRules, verbose: verbose)
    self.timeout = timeout
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    servers = try container.decode([SslocalServerDocument].self, forKey: .servers)
    locals = try container.decode([SslocalLocalDocument].self, forKey: .locals)
    pac = try container.decode(PACRuntimeDocument.self, forKey: .pac)
    timeout = try container.decodeIfPresent(Int.self, forKey: .timeout) ?? 60
  }

  func jsonData() throws -> Data {
    try Self.jsonEncoder.encode(self)
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
    case id, remarks, server, password, method, plugin
    case serverPort = "server_port"
    case pluginOpts = "plugin_opts"
  }
}

/// 三个本地端点与单一监听范围的派生设置。HTTP 入站可独立关闭，但启用时与
/// SOCKS、PAC 共用同一范围；默认端口沿用 Legacy 的 1086/1087/1089。
struct SslocalListenSettings: Equatable, Sendable {
  var scope: ListenScope = .loopback
  var socksPort: Int = 1086
  var httpProxyEnabled: Bool = true
  var httpPort: Int = 1087
  var pacPort: Int = 1089
  var udpRelayEnabled: Bool = false

  var bindAddress: String { scope.bindAddress }
  var advertisedAddress: String { scope.advertisedAddress }
  var mode: String { udpRelayEnabled ? "tcp_and_udp" : "tcp_only" }

  var locals: [SslocalLocalDocument] {
    var result = [
      SslocalLocalDocument(
        inboundProtocol: "socks",
        localAddress: bindAddress,
        localPort: socksPort,
        mode: mode)
    ]
    if httpProxyEnabled {
      result.append(
        SslocalLocalDocument(
          inboundProtocol: "http",
          localAddress: bindAddress,
          localPort: httpPort,
          mode: "tcp_only"))
    }
    return result
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

/// 监听指纹（spec #21 D5/D7）：服务器列表变化可热重载；任一本地入站或 PAC
/// endpoint 变化都必须由 wrapper 走优雅重启。
struct SslocalListenFingerprint: Equatable, Sendable {
  let locals: [SslocalLocalDocument]
  let pac: PACRuntimeDocument
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
    SslocalListenFingerprint(locals: locals, pac: pac)
  }

  var socksLocal: SslocalLocalDocument? {
    locals.first { $0.inboundProtocol == "socks" }
  }

  var socksAddress: String { socksLocal?.localAddress ?? "" }
  var socksPort: Int { socksLocal?.localPort ?? 0 }
  var socksMode: String { socksLocal?.mode ?? "" }

  /// wrapper 读取侧防御校验：端口、协议与共享范围必须一致；无效文件按 D5
  /// 停止并清理，不能交给 KeepAlive 无限重放。
  var isWellFormed: Bool {
    guard !servers.isEmpty else { return false }
    guard
      (1...65535).contains(pac.port),
      (1...86_400).contains(timeout),
      pac.endpointPath == PACRuntimeDocument.versionedEndpointPath,
      !pac.advertisedAddress.isEmpty
    else { return false }

    let expectedBind = pac.listenScope == .loopback ? "127.0.0.1" : "0.0.0.0"
    guard pac.bindAddress == expectedBind else {
      return false
    }
    switch pac.listenScope {
    case .loopback:
      guard pac.advertisedAddress == "127.0.0.1" else { return false }
    case .host:
      guard
        isIPv4Address(pac.advertisedAddress),
        pac.advertisedAddress != "0.0.0.0",
        pac.advertisedAddress != "127.0.0.1"
      else {
        return false
      }
    }

    let socks = locals.filter { $0.inboundProtocol == "socks" }
    let http = locals.filter { $0.inboundProtocol == "http" }
    guard socks.count == 1, http.count <= 1, locals.count == socks.count + http.count else {
      return false
    }
    guard socks[0].localPort == pac.socksPort else { return false }
    guard http.allSatisfy({ $0.mode == "tcp_only" }) else { return false }

    let localPorts = locals.map(\.localPort)
    guard Set(localPorts + [pac.port]).count == localPorts.count + 1 else { return false }
    guard
      locals.allSatisfy({ local in
        local.localAddress == expectedBind
          && (1...65535).contains(local.localPort)
          && (local.mode == "tcp_only" || local.mode == "tcp_and_udp")
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
