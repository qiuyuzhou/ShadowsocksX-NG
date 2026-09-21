import Foundation

// 代理运行时 wrapper（spec #21 D2/D5/D7，issue #27/#28）：LaunchAgent
// 常驻进程，读取跨进程契约 `sslocal-active.json`，承载 PAC HTTP endpoint，
// 并以绝对配置路径启动官方 sslocal、监管二者生命周期。
//
// 协议要点：
// - 显式停止（GUI 注销 → launchd SIGTERM 本进程）：SIGTERM 转发 sslocal 并
//   等待其退出，随后本进程以 0 退出；KeepAlive={SuccessfulExit:false} 不会
//   重启干净退出。
// - 崩溃恢复：sslocal 意外退出 → 本进程非零退出 → KeepAlive 重启并重放最后
//   有效快照（异常路径不触碰契约文件，D5）。
// - 变更协议：SIGUSR1 到达后重读契约；仅 `servers` 变化 → 转发 SIGUSR1 给
//   sslocal（上游热重载服务器列表）；监听地址/端口/协议/mode 结构性变化 →
//   优雅重启。
// - 契约缺失 → 干净退出（等待 GUI 重新写入并注册）；契约无效 → 普通 unlink
//   清理后干净退出，避免把上游必然拒绝的配置反复交给 sslocal。
//
// 测试缝（生产走默认值）：`SSXNG_CONTRACT_PATH`、`SSXNG_SSLOCAL_PATH`、
// `SSXNG_RUNTIME_DIR`（pid 文件与收敛日志的替代目录，测试隔离用）。

private let environment = ProcessInfo.processInfo.environment

private let contractURL: URL =
  environment["SSXNG_CONTRACT_PATH"].map { URL(fileURLWithPath: $0) }
  ?? RuntimePaths.runtimeFileURL()

private let sslocalURL: URL =
  environment["SSXNG_SSLOCAL_PATH"].map { URL(fileURLWithPath: $0) }
  ?? Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sslocal")

private let runtimeDirectoryOverride: URL? = environment["SSXNG_RUNTIME_DIR"].map {
  URL(fileURLWithPath: $0, isDirectory: true)
}

private let pidFileURL: URL =
  runtimeDirectoryOverride?.appendingPathComponent("agent.pid") ?? RuntimePaths.agentPIDFileURL()

// 顶层脚本是按源码顺序执行的：队列必须先于下方任何函数调用完成初始化。
private let signalsQueue = DispatchQueue(label: "com.qiuyuzhou.ShadowsocksX-NG2.agent.signals")

// wrapper 与 sslocal 的输出收敛到应用支持目录内的 0600 日志；launchd 统一日
// 志不承载代理细节。
redirectStandardStreams(
  to: runtimeDirectoryOverride?.appendingPathComponent("agent.log") ?? RuntimePaths.agentLogURL())

FileManager.default.createFile(
  atPath: pidFileURL.path,
  contents: Data("\(getpid())\n".utf8),
  attributes: [.posixPermissions: 0o600])

let exitStatus = supervise()
try? FileManager.default.removeItem(at: pidFileURL)
exit(exitStatus)

// MARK: - 监管循环

private func supervise() -> Int32 {
  let flags = SignalFlags()
  let stopSource = observeSignal(SIGTERM, flags: flags) { flags.requestStop() }
  let interruptSource = observeSignal(SIGINT, flags: flags) { flags.requestStop() }
  let reloadSource = observeSignal(SIGUSR1, flags: flags) { flags.requestReload() }
  defer {
    stopSource.cancel()
    interruptSource.cancel()
    reloadSource.cancel()
  }

  while true {
    let document: SslocalRuntimeDocument
    switch loadContract() {
    case .missing:
      RuntimeLog.emit(.contractMissing)
      return 0
    case .invalid:
      try? FileManager.default.removeItem(at: contractURL)
      RuntimeLog.emit(.contractInvalidRemoved)
      return 0
    case .loaded(let loaded):
      document = loaded
    }

    guard let child = spawnSslocal(document) else {
      RuntimeLog.emit(.sslocalSpawnFailed)
      return 0
    }

    let pacServer = PACServer(configuration: document.pac)
    do {
      try pacServer.start()
      RuntimeLog.emit(.pacStarted(port: document.pac.port))
    } catch {
      RuntimeLog.emit(
        .pacStartFailed(port: document.pac.port, detail: String(describing: error)))
      stopUnsupervisedChild(child)
      return 0
    }

    // 监听建立判定（issue #38，D10「3 秒未建立监听 → error 日志」）。
    awaitListenEstablishment(document: document, child: child, flags: flags)

    let listen = document.listenFingerprint

    switch superviseChild(child, pacServer: pacServer, listen: listen, flags: flags) {
    case .stoppedCleanly:
      return 0
    case .childLost:
      return 1
    case .restart:
      continue
    }
  }
}

/// PAC 尚未启动时的启动失败收敛；此时还没有 DispatchSource 收割子进程。
private func stopUnsupervisedChild(_ child: Process) {
  RuntimeLog.emit(.sslocalStopRequested)
  child.terminate()
  let deadline = Date().addingTimeInterval(10)
  while child.isRunning && Date() < deadline {
    Thread.sleep(forTimeInterval: 0.05)
  }
  if child.isRunning { kill(child.processIdentifier, SIGKILL) }
  child.waitUntilExit()
}

private enum SupervisionOutcome {
  /// 显式停止或契约缺失/无效：干净退出，launchd 不再重启。
  case stoppedCleanly
  /// 子进程意外退出：非零退出，交 KeepAlive 重放最后有效快照。
  case childLost
  /// 契约监听结构变化：重读文件并重新拉起。
  case restart
}

private func superviseChild(
  _ child: Process,
  pacServer: PACServer,
  listen: SslocalListenFingerprint,
  flags: SignalFlags
) -> SupervisionOutcome {
  let exitStatus = ExitStatusBox()
  // 单一收割点：waitUntilExit 只在这里调用，其余路径等 box 出值。
  let exitSource = DispatchSource.makeProcessSource(
    identifier: child.processIdentifier, eventMask: .exit, queue: signalsQueue)
  exitSource.setEventHandler {
    child.waitUntilExit()
    exitStatus.store(child.terminationStatus)
    flags.wake()
  }
  exitSource.resume()

  while true {
    flags.wait()
    if flags.consumeStop() {
      RuntimeLog.emit(.sslocalStopRequested)
      return stopCleanly(
        child: child, pacServer: pacServer, exitStatus: exitStatus, exitSource: exitSource,
        flags: flags)
    }
    if let status = exitStatus.load() {
      return handleUnexpectedExit(status, pacServer: pacServer, exitSource: exitSource)
    }
    guard flags.consumeReload() else { continue }

    switch loadContract() {
    case .missing:
      RuntimeLog.emit(.contractMissing)
      return stopCleanly(
        child: child, pacServer: pacServer, exitStatus: exitStatus, exitSource: exitSource,
        flags: flags)
    case .invalid:
      try? FileManager.default.removeItem(at: contractURL)
      RuntimeLog.emit(.contractInvalidRemoved)
      return stopCleanly(
        child: child, pacServer: pacServer, exitStatus: exitStatus, exitSource: exitSource,
        flags: flags)
    case .loaded(let reloaded):
      if reloaded.listenFingerprint != listen {
        RuntimeLog.emit(.reloadRestarted)
        stopRuntime(
          child: child, pacServer: pacServer, exitStatus: exitStatus, exitSource: exitSource,
          flags: flags)
        if flags.consumeStop() {
          return .stoppedCleanly
        }
        flags.rearmIfPending()
        return .restart
      }
      RuntimeLog.emit(.reloadForwarded)
      kill(child.processIdentifier, SIGUSR1)
    }
  }
}

private func stopCleanly(
  child: Process,
  pacServer: PACServer,
  exitStatus: ExitStatusBox,
  exitSource: DispatchSourceProcess,
  flags: SignalFlags
) -> SupervisionOutcome {
  stopRuntime(
    child: child, pacServer: pacServer, exitStatus: exitStatus, exitSource: exitSource, flags: flags
  )
  return .stoppedCleanly
}

private func handleUnexpectedExit(
  _ status: Int32,
  pacServer: PACServer,
  exitSource: DispatchSourceProcess
) -> SupervisionOutcome {
  pacServer.stop()
  RuntimeLog.emit(.pacStopped)
  RuntimeLog.emit(.sslocalExitedUnexpectedly(status: status))
  exitSource.cancel()
  return .childLost
}

private func stopRuntime(
  child: Process,
  pacServer: PACServer,
  exitStatus: ExitStatusBox,
  exitSource: DispatchSourceProcess,
  flags: SignalFlags
) {
  pacServer.stop()
  RuntimeLog.emit(.pacStopped)
  stopChild(child, exitStatus: exitStatus, exitSource: exitSource, flags: flags)
}

private func stopChild(
  _ child: Process,
  exitStatus: ExitStatusBox,
  exitSource: DispatchSourceProcess,
  flags: SignalFlags
) {
  kill(child.processIdentifier, SIGTERM)
  let gracefulDeadline = DispatchTime.now() + 10
  while exitStatus.load() == nil {
    if flags.wait(timeout: gracefulDeadline) == .timedOut {
      kill(child.processIdentifier, SIGKILL)
      _ = flags.wait(timeout: DispatchTime.now() + 5)
    }
  }
  exitSource.cancel()
  flags.rearmIfPending()
}

// MARK: - 监听建立判定

/// 监听判定时限（D10）：sslocal 拉起后 3 秒内应完成本地监听绑定。
private let listenEstablishmentDeadline: TimeInterval = 3
/// 单次探测超时与轮询间隔；正常启动百毫秒级完成，超时路径总耗时不超时限太多。
private let listenProbeTimeout: TimeInterval = 0.25
private let listenProbeInterval: TimeInterval = 0.1

/// sslocal 拉起后阻塞监管线程至多 3 秒轮询契约内的本地端点（运行期失败以
/// sslocal 信号为准，issue #38）：全部端点就绪即返回；信号（停止/重载/子进程
/// 退出）到达即让位交还监管循环；超时且子进程仍在 → 记 error 日志但继续监管
/// （GUI 健康门负责呈现，wrapper 不做启停决策）。
private func awaitListenEstablishment(
  document: SslocalRuntimeDocument,
  child: Process,
  flags: SignalFlags
) {
  let deadline = DispatchTime.now() + listenEstablishmentDeadline
  while DispatchTime.now() < deadline {
    if document.locals.allSatisfy({ local in
      EndpointHealthProbe.probe(
        host: local.probeHost,
        port: local.localPort,
        timeout: listenProbeTimeout) == .reachable
    }) {
      return
    }
    if flags.wait(timeout: .now() + listenProbeInterval) == .success {
      flags.rearmIfPending()
      return
    }
  }
  guard child.isRunning else { return }  // 已退出：退出事件自带点名日志
  let endpoints = document.locals
    .map { "\($0.inboundProtocol) \($0.localAddress):\($0.localPort)" }
    .joined(separator: ", ")
  RuntimeLog.emit(.listenNotEstablished(detail: endpoints))
}

// MARK: - 信号与共享状态

/// 信号只置位并唤醒监管循环，全部判定在循环线程完成。标志与信号量成对
/// （辅助等待会消耗信号量，事后 rearmIfPending 补回）。
private final class SignalFlags {
  private let lock = NSLock()
  private var stopRequested = false
  private var reloadRequested = false
  private let events = DispatchSemaphore(value: 0)

  func requestStop() {
    lock.lock()
    stopRequested = true
    lock.unlock()
    events.signal()
  }

  func requestReload() {
    lock.lock()
    reloadRequested = true
    lock.unlock()
    events.signal()
  }

  func wake() {
    events.signal()
  }

  func wait() {
    events.wait()
  }

  func wait(timeout: DispatchTime) -> DispatchTimeoutResult {
    events.wait(timeout: timeout)
  }

  func consumeStop() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let value = stopRequested
    stopRequested = false
    return value
  }

  func consumeReload() -> Bool {
    lock.lock()
    defer { lock.unlock() }
    let value = reloadRequested
    reloadRequested = false
    return value
  }

  func rearmIfPending() {
    lock.lock()
    let pending = stopRequested || reloadRequested
    lock.unlock()
    if pending {
      events.signal()
    }
  }
}

private func observeSignal(_ number: Int32, flags: SignalFlags, handler: @escaping () -> Void)
  -> DispatchSourceSignal
{
  signal(number, SIG_IGN)
  let source = DispatchSource.makeSignalSource(signal: number, queue: signalsQueue)
  source.setEventHandler(handler: handler)
  source.resume()
  return source
}

/// 子进程退出状态的单一写入点（handler 线程）与读取点（监管线程），由
/// 信号量唤醒提供 happens-before。
private final class ExitStatusBox {
  private let lock = NSLock()
  private var value: Int32?

  func store(_ status: Int32) {
    lock.lock()
    value = status
    lock.unlock()
  }

  func load() -> Int32? {
    lock.lock()
    defer { lock.unlock() }
    return value
  }
}

// MARK: - 契约与子进程

private enum ContractLoad {
  case missing
  case invalid
  case loaded(SslocalRuntimeDocument)
}

private func loadContract() -> ContractLoad {
  guard let data = try? Data(contentsOf: contractURL) else { return .missing }
  guard let document = SslocalRuntimeDocument.decodeValidated(data) else { return .invalid }
  return .loaded(document)
}

private func spawnSslocal(_ document: SslocalRuntimeDocument) -> Process? {
  guard FileManager.default.isExecutableFile(atPath: sslocalURL.path) else { return nil }
  let child = Process()
  child.executableURL = sslocalURL
  child.arguments = ["-c", contractURL.path]
  var childEnvironment = environment
  // 上游默认日志级别会把服务器地址写进普通日志（D5）：常规模式压到 warn，
  // 用户明确打开 verbose 后才放宽到 debug。显式外部 RUST_LOG 仍可用于诊断。
  if childEnvironment["RUST_LOG"] == nil {
    childEnvironment["RUST_LOG"] = document.pac.verbose ? "debug" : "warn"
  }
  child.environment = childEnvironment
  do {
    try child.run()
  } catch {
    return nil
  }
  RuntimeLog.emit(.sslocalSpawned(pid: child.processIdentifier))
  return child
}

// MARK: - 日志收敛

private func redirectStandardStreams(to logURL: URL) {
  let fileManager = FileManager.default
  let directory = logURL.deletingLastPathComponent()
  try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  if fileManager.fileExists(atPath: logURL.path) {
    let attributes = try? fileManager.attributesOfItem(atPath: logURL.path)
    if let size = attributes?[.size] as? UInt64, size > 1_048_576 {
      // 启动时超限即截断；滚动与诊断导出由 #33 完善。
      try? fileManager.removeItem(at: logURL)
    }
  }
  if !fileManager.fileExists(atPath: logURL.path) {
    fileManager.createFile(
      atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
  }
  try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
  freopen(logURL.path, "a", stdout)
  freopen(logURL.path, "a", stderr)
}
