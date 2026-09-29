import Foundation

// MARK: - 防火墙呈现、wrapper 观测与系统代理门禁

extension ProxyRuntimeController {
  func presentFirewallStatus(for document: SslocalRuntimeDocument) async {
    guard document.listen.listenerMode.exposesNetworkInterfaces else {
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

  /// 系统代理收敛：意图开启 + agent 健康 + 所选模式具备可用出口才应用；
  /// 条件关闭时清除匹配的端点配置并保持待应用，条件恢复后自动重写。
  func convergeSystemProxy(forceCleanup: Bool = false) async {
    guard settings.systemProxyEnabled else { return }
    guard systemProxyExitAvailable, let document = lastDocument else {
      if !forceCleanup, case .pending = systemProxyState { return }
      switch clearRecognizedSystemProxyOutcome() {
      case .idle, .pending, .applied:
        systemProxyState = .pending
      case .failed(let failure):
        systemProxyState = .failed(failure)
      }
      return
    }
    do {
      let configuration = try proxyMode.systemProxyConfiguration(
        for: document, exceptions: settings.proxyExceptionList)
      let outcome = try systemProxy.apply(configuration)
      if outcome == .unchanged {
        // 值语义等价的零写入路径：事件行供排障回答「这次为何没有授权弹窗」。
        RuntimeLog.emit(.systemProxyUnchanged)
      }
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

  /// agent 入站不可用时清除可识别的端点设置；意图保留为待应用。
  func withdrawSystemProxyAfterEntryLoss() async {
    guard settings.systemProxyEnabled else {
      systemProxyState = .idle
      return
    }
    switch clearRecognizedSystemProxyOutcome() {
    case .idle, .pending, .applied:
      systemProxyState = .pending
    case .failed(let failure):
      systemProxyState = .failed(failure)
    }
  }

  /// 清除与最近一次尝试端点签名匹配的系统代理配置。
  func clearRecognizedSystemProxyOutcome() -> SystemProxyControlState {
    do {
      try systemProxy.clearRecognizedSettings()
      return .idle
    } catch {
      return .failed(systemProxyFacts(for: error))
    }
  }

  func startEnabledSystemProxyObservation() {
    guard systemProxyObservationMode != .enabled else { return }
    systemProxyObservationMode = .enabled
    systemProxyNetworkChangeMonitor.start { [weak self] change in
      self?.handleSystemProxyNetworkChange(change)
    }
  }

  func clearAndStopSystemProxyObservation() async -> SystemProxyControlState {
    if let systemProxyCleanupTask { return await systemProxyCleanupTask.value }
    let task = Task { @MainActor [weak self] in
      guard let self else { return SystemProxyControlState.idle }
      return await performSystemProxyCleanupUntilQuiet()
    }
    systemProxyCleanupTask = task
    let result = await task.value
    systemProxyCleanupTask = nil
    return result
  }

  private func performSystemProxyCleanupUntilQuiet() async -> SystemProxyControlState {
    if systemProxyObservationMode != .enabled {
      systemProxyObservationMode = .cleanup
      systemProxyNetworkChangeMonitor.start { [weak self] change in
        self?.handleSystemProxyNetworkChange(change)
      }
    } else {
      systemProxyObservationMode = .cleanup
    }

    var outcome: SystemProxyControlState = .idle
    repeat {
      systemProxyCleanupRescanRequested = false
      outcome = clearRecognizedSystemProxyOutcome()
      // Let queued SystemConfiguration notifications reach the main actor. Any
      // location/service/proxy change during this cleanup starts another full scan.
      try? await Task.sleep(nanoseconds: 100_000_000)
      await Task.yield()
    } while systemProxyCleanupRescanRequested

    systemProxyNetworkChangeMonitor.stop()
    systemProxyObservationMode = .stopped
    return outcome
  }

  private func handleSystemProxyNetworkChange(_ change: SystemProxyNetworkChange) {
    switch systemProxyObservationMode {
    case .stopped:
      return
    case .cleanup:
      if !change.isDisjoint(with: [.networkConfiguration, .proxyConfiguration]) {
        systemProxyCleanupRescanRequested = true
      }
    case .enabled:
      guard settings.systemProxyEnabled else { return }
      // Proxy-only changes are deliberately ignored while enabled: competing proxy
      // software must not create a write loop. Location/service/path changes reapply.
      guard !change.isDisjoint(with: [.networkConfiguration, .networkPath]) else {
        return
      }
      guard !systemProxyConvergenceScheduled else { return }
      systemProxyConvergenceScheduled = true
      Task { @MainActor [weak self] in
        await Task.yield()
        guard let self else { return }
        self.systemProxyConvergenceScheduled = false
        await self.convergeSystemProxy(forceCleanup: true)
      }
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
    case .invalidStoredConfiguration: return .operation(.invalidStoredConfiguration)
    case .cannotWriteService: return .operation(.cannotWriteService)
    case .commitFailed: return .operation(.commitFailed)
    case .applyFailed: return .operation(.applyFailed)
    case .noNetworkLocations: return .operation(.noNetworkLocations)
    case .endpointSignatureStoreFailed: return .operation(.endpointSignatureStoreFailed)
    }
  }
}
