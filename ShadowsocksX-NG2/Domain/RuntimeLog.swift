import Foundation

/// 运行时日志基线（spec #21 D5）：事件是封闭枚举，脱敏由构造保证——永不
/// 携带密码、插件参数、Keychain 值、完整订阅 URL、URL token 或运行时 JSON
/// 内容；服务器地址与备注默认不进普通日志（端点探测失败点名的 host:port
/// 是本机监听端点，属 D8 要求呈现的事实字段，不受此限）。日志落盘与诊断
/// 导出由 #33 在本事件流上接出。
enum RuntimeLogEvent: CustomStringConvertible, Sendable {
  /// 契约文件已原子写入（只携带数量元数据，非内容）。
  case contractWritten(serverCount: Int)
  /// 契约内容与磁盘一致，跳过写入（幂等）。
  case contractUnchanged
  /// 运行时文件已清理。
  case runtimeFilesDeleted
  /// 激活状态等运行时元数据落盘失败（不含内容）。
  case runtimePersistFailed(detail: String)
  case agentRegistered
  case agentRegisterFailed(detail: String)
  case agentUnregistered
  case agentUnregisterFailed(detail: String)
  /// wrapper 侧 sslocal 监管事件。
  case sslocalSpawned(pid: Int32)
  case sslocalSpawnFailed
  case sslocalExitedUnexpectedly(status: Int32)
  case sslocalStopRequested
  case pacStarted(port: Int)
  case pacStartFailed(port: Int, detail: String)
  case pacStopped
  case contractMissing
  case contractInvalidRemoved
  case reloadForwarded
  case reloadRestarted
  /// 本机代理端点启动后未就绪（点名端点与端口，D8）。
  case endpointProbeFailed(host: String, port: Int, detail: String)
  /// 激活失败或活动目标清除（原因枚举已点名且不含秘密）。
  case activationFailed(reason: String)

  var description: String {
    switch self {
    case .contractWritten(let serverCount):
      return "contract written (servers=\(serverCount))"
    case .contractUnchanged:
      return "contract unchanged, write skipped"
    case .runtimeFilesDeleted:
      return "runtime files deleted"
    case .runtimePersistFailed(let detail):
      return "runtime metadata persist failed: \(detail)"
    case .agentRegistered:
      return "launch agent registered"
    case .agentRegisterFailed(let detail):
      return "launch agent register failed: \(detail)"
    case .agentUnregistered:
      return "launch agent unregistered"
    case .agentUnregisterFailed(let detail):
      return "launch agent unregister failed: \(detail)"
    case .sslocalSpawned(let pid):
      return "sslocal spawned (pid=\(pid))"
    case .sslocalSpawnFailed:
      return "sslocal spawn failed"
    case .sslocalExitedUnexpectedly(let status):
      return "sslocal exited unexpectedly (status=\(status))"
    case .sslocalStopRequested:
      return "sslocal stop requested"
    case .pacStarted(let port):
      return "PAC endpoint started (port=\(port))"
    case .pacStartFailed(let port, let detail):
      return "PAC endpoint failed (port=\(port)): \(detail)"
    case .pacStopped:
      return "PAC endpoint stopped"
    case .contractMissing:
      return "contract missing"
    case .contractInvalidRemoved:
      return "contract invalid, removed"
    case .reloadForwarded:
      return "reload forwarded to sslocal"
    case .reloadRestarted:
      return "reload: listen change, restarting sslocal"
    case .endpointProbeFailed(let host, let port, let detail):
      return "endpoint \(host):\(port) not ready: \(detail)"
    case .activationFailed(let reason):
      return "activation failed: \(reason)"
    }
  }
}

/// 敏感信息脱敏工具（D5「敏感信息」定义的读取面）。
enum Redactor {
  /// 非空远程 URL 只保留 scheme+host：路径、查询与片段全部略去，完整订阅
  /// URL 与 URL token 永不入日志。解析失败一律归并为占位符。
  static func remoteURL(_ url: String) -> String {
    guard let parsed = URL(string: url), let host = parsed.host(), !host.isEmpty else {
      return "<redacted-url>"
    }
    return "\(parsed.scheme ?? "https")://\(host)/…"
  }

  /// 运行时文档只允许暴露数量与模式元数据。
  static func documentSummary(_ document: SslocalRuntimeDocument) -> String {
    let protocols = document.locals.map(\.inboundProtocol).joined(separator: ",")
    return "servers=\(document.servers.count) protocols=\(protocols) mode=\(document.socksMode)"
  }
}

/// 事件发射缝：wrapper 与 GUI 共用 stderr 行式输出（wrapper 侧由 launchd/
/// agent.log 收敛，GUI 侧进系统日志）。
enum RuntimeLog {
  static func emit(_ event: RuntimeLogEvent) {
    let line = "ssxng: \(event.description)\n"
    FileHandle.standardError.write(Data(line.utf8))
  }
}
