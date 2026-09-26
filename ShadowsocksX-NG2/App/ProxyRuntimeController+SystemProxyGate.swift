import Foundation

// MARK: - 防火墙呈现、wrapper 观测与系统代理门禁（issue #60）

extension ProxyRuntimeController {
  func presentFirewallStatus(for document: SslocalRuntimeDocument) async {
    guard document.listen.listenScope == .host else {
      state = .running
      return
    }
    if let blocked = await blockedFirewallExecutable() {
      presentFirewallBlocked(blocked)
      return
    }
    state = .running
    observeFirewall(generation: flowGeneration)
  }

  private func blockedFirewallExecutable() async -> URL? {
    for executableURL in firewallExecutableURLs {
      let status = await firewallStatus(for: executableURL)
      if status == .blocked { return executableURL }
    }
    return nil
  }

  private func presentFirewallBlocked(_ executableURL: URL) {
    let name = executableURL.lastPathComponent
    state = .firewallBlocked(FirewallBlockedFacts(executableName: name))
  }

  private func observeFirewall(generation: Int) {
    firewallObservationTask?.cancel()
    let interval = firewallPollIntervalNanoseconds
    firewallObservationTask = Task { @MainActor [weak self] in
      while !Task.isCancelled {
        try? await Task.sleep(nanoseconds: interval)
        guard !Task.isCancelled, let self, generation == flowGeneration else { return }
        if let blocked = await blockedFirewallExecutable() {
          presentFirewallBlocked(blocked)
          firewallObservationTask = nil
          return
        }
      }
    }
  }

  func cancelFirewallObservation() {
    firewallObservationTask?.cancel()
    firewallObservationTask = nil
  }

  private func firewallStatus(for executableURL: URL) async -> FirewallBlockStatus {
    let checker = firewallChecker
    return await Task.detached(priority: .utility) {
      checker.status(for: executableURL)
    }.value
  }

  func probeAsync(
    host: String, port: Int, timeout: TimeInterval
  ) async -> EndpointHealthProbe.Outcome {
    let probe = probe
    return await Task.detached(priority: .utility) {
      probe.probe(host: host, port: port, timeout: timeout)
    }.value
  }

  /// 显式停止协议次序（D2）：注销（SIGTERM wrapper → wrapper 停 sslocal 并
  /// 等待）完成后才允许后续删文件动作。最多等 5 秒，超时也继续（launchd 会
  /// 兜底结束进程）。
  func waitForWrapperExit() async {
    let deadline = Date().addingTimeInterval(5)
    while wrapperState() != .notRunning && Date() < deadline {
      try? await Task.sleep(nanoseconds: 100_000_000)
    }
  }

  func wrapperState() -> WrapperProcessState {
    guard
      let data = try? Data(contentsOf: runtimeFileStore.pidFileURL),
      let text = String(data: data, encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines),
      let pid = Int32(text)
    else { return .notRunning }
    guard sendSignal(pid, 0) == 0 else { return .notRunning }
    return .running(pid: pid)
  }

  // MARK: - 目录同步

  /// Re-expands one command-start snapshot; a concurrently published catalog
  /// is intentionally observed by the next command, not halfway through this one.
  func reexpand(in catalog: ConfigurationCatalog) -> ActivationEffect? {
    let effect = machine.catalogDidCommit(
      catalog, credentials: credentials, plugins: plugins,
      options: settings.runtimeDocumentOptions)
    activeTargetID = machine.activeTargetID
    switch effect {
    case .deployed(let configuration):
      skippedServers = configuration.skippedServers
    case .clearedAndStopped:
      skippedServers = []
    case nil:
      break
    }
    return effect
  }

  func describe(_ error: Error) -> String {
    String(describing: error)
  }

  // MARK: - 系统代理门禁（issue #60）

  /// 系统代理收敛：意图开启 + agent 健康 + 所选模式具备可用出口（活动目标
  /// 通过本地预检）才写入；否则保持待应用，条件恢复后随下次收敛自动应用。
  /// 意图关闭时不做任何事（呈现面保持 idle/既有失败态）。
  func convergeSystemProxy() async {
    guard settings.systemProxyEnabled else { return }
    guard systemProxyExitAvailable, let document = lastDocument else {
      if case .pending = systemProxyState { return }
      switch restoreSystemProxyOutcome() {
      case .idle:
        systemProxyState = .pending
      case .failed(let failure):
        systemProxyState = .failed(failure)
      case .pending, .applied:
        systemProxyState = .pending
      }
      return
    }
    do {
      let configuration = try proxyMode.systemProxyConfiguration(
        for: document, exceptions: settings.proxyExceptionList)
      try systemProxy.apply(configuration)
      systemProxyState = .applied
    } catch {
      systemProxyState = .failed(systemProxyFacts(for: error))
    }
  }

  /// 出口可用 = agent 入站健康（回环入口可用，含防火墙仅阻主机态的情形）
  /// 且模式有出口；直连不依赖活动服务器目标。
  private var systemProxyExitAvailable: Bool {
    switch state {
    case .running, .firewallBlocked:
      return proxyMode == .direct || activeTargetID != nil
    case .off, .starting, .launchFailed, .requiresApproval, .serviceFailed:
      return false
    }
  }

  /// agent 入站不可用（启动失败、目标清除、监听设置不可读）时的安全撤回：
  /// 尽力恢复 NG2 持有的系统设置；意图保留为待应用，条件恢复后自动收敛。
  /// 恢复失败以 typed 呈现——系统设置仍被 NG2 持有时用户必须知道。
  func withdrawSystemProxyAfterEntryLoss() async {
    if let error = restoreSystemProxyError() {
      systemProxyState = .failed(systemProxyFacts(for: error))
      return
    }
    systemProxyState = settings.systemProxyEnabled ? .pending : .idle
  }

  /// 恢复 NG2 持有的系统设置；成功 → `.idle`，失败 → typed 失败。
  func restoreSystemProxyOutcome() -> SystemProxyControlState {
    if let error = restoreSystemProxyError() {
      return .failed(systemProxyFacts(for: error))
    }
    return .idle
  }

  func restoreSystemProxyError() -> Error? {
    do {
      try systemProxy.restore()
      return nil
    } catch {
      return error
    }
  }

  func systemProxyFacts(for error: Error) -> SystemProxyFailureFacts {
    if let error = error as? SystemProxyError {
      return Self.systemProxyFacts(for: error)
    }
    if let error = error as? ProxyModeError {
      return .mode(error)
    }
    return .unknown
  }

  // 显式映射保持与错误族一一对应；错误带关联值，无法用字典键穷举。
  // swiftlint:disable:next cyclomatic_complexity
  private static func systemProxyFacts(
    for error: SystemProxyError
  ) -> SystemProxyFailureFacts {
    switch error {
    case .authorizationFailed: return .operation(.authorizationFailed)
    case .preferencesUnavailable: return .operation(.preferencesUnavailable)
    case .preferencesBusy: return .operation(.preferencesBusy)
    case .noCurrentNetworkSet: return .operation(.noCurrentNetworkSet)
    case .noProxyServices: return .operation(.noProxyServices)
    case .unreadableService: return .operation(.unreadableService)
    case .ownershipConflict: return .ownershipConflict
    case .invalidStoredConfiguration: return .operation(.invalidStoredConfiguration)
    case .cannotWriteService: return .operation(.cannotWriteService)
    case .commitFailed: return .operation(.commitFailed)
    case .applyFailed: return .operation(.applyFailed)
    case .ownershipStoreFailed: return .operation(.ownershipStoreFailed)
    }
  }
}
