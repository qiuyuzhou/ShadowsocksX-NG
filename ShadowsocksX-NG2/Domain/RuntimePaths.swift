import Foundation

/// 跨进程运行时路径契约（spec #21 D5，issue #27）：GUI 写、wrapper 读的固定
/// 位置。目录 0700、文件 0600，由写入方与 wrapper 共同维护。
enum RuntimePaths {
  static func runtimeDirectory() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("ShadowsocksX-NG2", isDirectory: true)
  }

  /// sslocal 配置契约：激活派生的完整 JSON，GUI 原子写入、wrapper 以绝对路径
  /// 交给 `sslocal -c`（也是 SIGUSR1 热重载时上游重读的文件）。
  static func runtimeFileURL() -> URL {
    runtimeDirectory().appendingPathComponent("sslocal-active.json")
  }

  /// wrapper 进程 pid 文件：SMAppService.Status 不暴露运行中 agent 的 pid，
  /// wrapper 自写此文件供 GUI 判活（kill(pid, 0)）并投递 SIGUSR1。
  static func agentPIDFileURL() -> URL {
    runtimeDirectory().appendingPathComponent("agent.pid")
  }

  /// wrapper 与 sslocal 的收敛日志（stderr 重定向目标）；滚动与诊断导出由 #33
  /// 完善。不属于「运行时文件」，显式停止时不删除。
  static func agentLogURL() -> URL {
    runtimeDirectory().appendingPathComponent("agent.log")
  }

  /// Original network-service proxy dictionaries captured before 2.0 writes
  /// system proxy settings. It is protected like the other runtime files.
  static func systemProxyOwnershipURL() -> URL {
    runtimeDirectory().appendingPathComponent("system-proxy-ownership.json")
  }
}
