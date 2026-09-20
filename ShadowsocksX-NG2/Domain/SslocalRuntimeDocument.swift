import Foundation

/// sslocal 运行时文档（spec #21 D5）：激活派生出的完整 JSON 契约文档，字段名与
/// shadowsocks-rust v1.25.0 对齐（docs/research/wayfinder-issue-2.md §2.2）。
/// 密码与插件参数已在此解析为明文——只供 #27 落盘运行时文件，永不入日志。
struct SslocalRuntimeDocument: Codable, Equatable, Sendable {
  let servers: [SslocalServerDocument]
  let localAddress: String
  let localPort: Int
  /// 本地入站协议（sslocal `protocol` 字段；HTTP 入站与监听范围由 #28 接线）。
  let inboundProtocol: String
  /// tcp_only / tcp_and_udp；TCP/UDP 自动选择由上游 PingBalancer 负责（D2）。
  let mode: String

  enum CodingKeys: String, CodingKey {
    case servers, mode
    case localAddress = "local_address"
    case localPort = "local_port"
    case inboundProtocol = "protocol"
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

/// sslocal 监听字段：用户设置的透传（端口语义 #30、监听范围与 HTTP 入站 #28
/// 各自接线，本层不解释）。出厂值沿用 Legacy 基线（D8）：回环 127.0.0.1、SOCKS5 1086。
struct SslocalListenSettings: Equatable, Sendable {
  var localAddress: String = "127.0.0.1"
  var localPort: Int = 1086
  var inboundProtocol: String = "socks"
  var udpRelayEnabled: Bool = false

  /// 上游 `mode` 字段取值。
  var mode: String { udpRelayEnabled ? "tcp_and_udp" : "tcp_only" }
}

/// 监听指纹（spec #21 D5 变更协议）：SIGUSR1 只能热重载 `servers`，这四个
/// 字段变化必须由 wrapper 走优雅重启。服务器列表变化不影响指纹。
struct SslocalListenFingerprint: Equatable, Sendable {
  let localAddress: String
  let localPort: Int
  let inboundProtocol: String
  let mode: String
}

extension SslocalRuntimeDocument {
  /// 读取侧单缝（GUI 与 wrapper 共用同一判定，防跨进程漂移）：解码成功且
  /// 结构有效才返回文档；否则按「文件无效」处理。
  static func decodeValidated(_ data: Data) -> SslocalRuntimeDocument? {
    guard
      let document = try? JSONDecoder().decode(SslocalRuntimeDocument.self, from: data),
      document.isWellFormed
    else { return nil }
    return document
  }

  /// 监听指纹，供 wrapper 判定「结构性变化」。
  var listenFingerprint: SslocalListenFingerprint {
    SslocalListenFingerprint(
      localAddress: localAddress,
      localPort: localPort,
      inboundProtocol: inboundProtocol,
      mode: mode)
  }

  /// 读取侧防御校验（wrapper 与 GUI 共用）：契约可解码但结构性无效时按
  /// 「文件无效」处理——停止并清理，避免把上游必然拒绝的配置反复交给 sslocal
  /// 造成 KeepAlive 重启循环。写入侧文档由激活状态机派生，天然满足。
  var isWellFormed: Bool {
    guard (1...65535).contains(localPort), !localAddress.isEmpty else { return false }
    guard !servers.isEmpty else { return false }
    return servers.allSatisfy { server in
      (1...65535).contains(server.serverPort)
        && !server.id.isEmpty
        && !server.server.isEmpty
        && !server.method.isEmpty
    }
  }
}
