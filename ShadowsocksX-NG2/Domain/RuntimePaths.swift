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

  /// ACL 稳定链接（ADR-0011）：sslocal 经契约 `acl` 键读取；指向某个
  /// `acl-<summary>.ini` 变体，换模式只改链接指向。
  static func aclFileURL() -> URL {
    runtimeDirectory().appendingPathComponent("acl-active.ini")
  }

  /// wrapper 进程 pid 文件：SMAppService.Status 不暴露运行中 agent 的 pid，
  /// wrapper 自写此文件供 GUI 判活（kill(pid, 0)）并投递 SIGUSR1。
  static func agentPIDFileURL() -> URL {
    runtimeDirectory().appendingPathComponent("agent.pid")
  }

  /// The wrapper's sslocal deployment receipt. ACL-backed receipts are written
  /// after the child owns the configured TCP listeners; the GUI checks its
  /// digest and PID during direct-mode health checks.
  static func agentRuntimeStatusURL() -> URL {
    runtimeDirectory().appendingPathComponent("agent-runtime-status.json")
  }

  /// wrapper 与 sslocal 的收敛日志（stderr 重定向目标）；滚动与诊断导出由 #33
  /// 完善。不属于「运行时文件」，显式停止时不删除。
  static func agentLogURL() -> URL {
    runtimeDirectory().appendingPathComponent("agent.log")
  }

  /// Last endpoint signature attempted by NG2, used only to identify settings to clear.
  static func systemProxyEndpointSignatureURL() -> URL {
    runtimeDirectory().appendingPathComponent("system-proxy-endpoint-signature.json")
  }

  /// Legacy snapshot file from the ownership-based lifecycle. It is read once only
  /// to extract a single unambiguous applied endpoint signature, then deleted.
  static func legacySystemProxyOwnershipURL() -> URL {
    runtimeDirectory().appendingPathComponent("system-proxy-ownership.json")
  }
}

/// ACL 活动链接的防逃逸校验（ADR-0011）：解析 symlink 后必须仍是运行目录
/// 内的普通文件。目录与目标都做 symlink 解析，避免 `/var` vs `/private/var`
/// 造成假阴性。GUI 写入侧与 Agent 加载侧共用此判定。
enum ACLActiveLinkPolicy {
  static func resolvesToRegularFile(inside directory: URL, linkURL: URL) -> Bool {
    let fileManager = FileManager.default
    let linkPath = linkURL.standardizedFileURL.path
    guard fileManager.fileExists(atPath: linkPath) else { return false }
    let resolved = URL(fileURLWithPath: linkPath).resolvingSymlinksInPath().standardizedFileURL
    let resolvedDirectory = URL(fileURLWithPath: directory.path).resolvingSymlinksInPath()
      .standardizedFileURL.path
    guard resolved.path == resolvedDirectory || resolved.path.hasPrefix(resolvedDirectory + "/")
    else { return false }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: resolved.path, isDirectory: &isDirectory) else {
      return false
    }
    return !isDirectory.boolValue
  }
}
