import Foundation

// MARK: - 用户意图与收敛（命令面）

extension ProxyRuntimeController {
  // MARK: - 用户意图

  /// 激活一个服务器或分组目标（目录 UI 工单复用入口）：持久化目标；agent
  /// 意图开启时立即把新档推到运行时。激活原子失败时目标与运行时完全不动
  /// （D3），点名原因进 `lastActivationFailure` 并返回 `.rejectedActivation`；
  /// 意外错误 throws 并进入 `serviceFailed`。
  @discardableResult
  func activate(_ target: NodeID) async throws -> ActivationCommandOutcome {
    let catalog = catalogSnapshotReader.catalogSnapshot
    do {
      let configuration = try machine.activate(
        target, in: catalog, credentials: credentials, plugins: plugins,
        options: settings.runtimeDocumentOptions)
      activeTargetID = target
      skippedServers = configuration.skippedServers
      lastActivationFailure = nil
      do {
        try activationFileStore.save(activeTargetID: target)
      } catch {
        state = .serviceFailed(.persistence)
        throw error
      }
      if settings.agentEnabled {
        await deploy(configuration.document)
      }
      return .activated(skippedInvalid: configuration.skippedServers.count)
    } catch let failure as ActivationFailure {
      lastActivationFailure = failure
      return .rejectedActivation
    } catch {
      state = .serviceFailed(.unknown)
      throw error
    }
  }

  /// Agent 开关（issue #60）：先持久化意图（显式关闭在 GUI 重启后仍生效），
  /// 再收敛运行时。持久化失败保留现状并点名，不静默偏离持久化事实。意图已
  /// 开启时的开启命令仅在未达健康态时重收敛——它是启动失败/重置后的显式
  /// 重试入口；健康运行中不做无谓的注销重拉。
  func setAgentEnabled(_ enabled: Bool) async {
    if enabled == settings.agentEnabled {
      guard enabled else { return }
      switch state {
      case .off, .launchFailed, .serviceFailed:
        await convergeAgent()
      case .starting, .running, .firewallBlocked, .requiresApproval:
        break
      }
      return
    }
    var next = settings
    next.agentEnabled = enabled
    do {
      try settingsStore.save(next)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.persistence)
      return
    }
    settings = next
    if enabled {
      await convergeAgent()
    } else {
      await stopAgent()
    }
  }

  /// 系统代理开关（issue #60）：只写写/恢复 NG2 持有的系统设置；不注销
  /// agent、不停止本地 SOCKS/HTTP 监听。
  func setSystemProxyEnabled(_ enabled: Bool) async {
    guard enabled != settings.systemProxyEnabled else { return }
    var next = settings
    next.systemProxyEnabled = enabled
    do {
      try settingsStore.save(next)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.persistence)
      return
    }
    settings = next
    if enabled {
      await convergeSystemProxy()
    } else {
      systemProxyState = restoreSystemProxyOutcome()
    }
  }

  /// GUI 启动重同步（D5「GUI 下次启动重新校验同步」；issue #60）：agent 意图
  /// 来自持久化设置——开启则自动注册/收敛 LaunchAgent 并部署（无活动目标时
  /// 以空服务器列表提供监听）；关闭则恢复系统代理后按停止协议收敛。GUI 崩溃
  /// 期间 agent 与 wrapper 均不受影响。
  func resyncOnLaunch() async {
    guard settings.agentEnabled else {
      await stopAgent()
      return
    }
    let catalog = catalogSnapshotReader.catalogSnapshot
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      await deploy(configuration.document)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
    case nil:
      await deployListeningWithoutTarget()
    }
  }

  // MARK: - 动作执行

  /// Agent 意图开启的收敛：注册态不是事实来源，意图才是——未注册也会注册
  /// （首次运行默认开启），已注册则重校验目标并部署。
  private func convergeAgent() async {
    let catalog = catalogSnapshotReader.catalogSnapshot
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      await deploy(configuration.document)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
    case nil:
      await deployListeningWithoutTarget()
    }
  }

  /// Agent 意图关闭的收敛（issue #60 验收次序）：先按 ownership 规则恢复
  /// NG2 持有的系统设置，再注销 agent 停止本地监听并清理运行时文件。
  func stopAgent() async {
    let restoreError = restoreSystemProxyError()
    _ = await execute(.stop, document: nil)
    state = .off
    lastDocument = nil
    skippedServers = []
    lastActivationFailure = nil
    systemProxyState = restoreError.map { .failed(systemProxyFacts(for: $0)) } ?? .idle
  }

  /// 无活动目标时 agent 仍提供本地监听（issue #60）：空服务器列表文档，
  /// SOCKS/HTTP 端点照常绑定；系统代理门禁会因缺少可用出口保持待应用。
  func deployListeningWithoutTarget() async {
    let document = SslocalRuntimeDocument(
      servers: [],
      listen: settings.listen,
      timeout: settings.timeoutSeconds,
      verbose: settings.verboseLogging)
    await deploy(document)
  }

  /// 把「运行定义档」意图推到运行时：计划动作 → 顺序执行 → 端点健康呈现。
  @discardableResult
  func deploy(_ sourceDocument: SslocalRuntimeDocument) async -> Bool {
    if listenSettingsUnreadable || settingsUnreadable {
      await refuseDeployForUnreadableListenSettings()
      return false
    }
    let document: SslocalRuntimeDocument
    do {
      document = try runtimeDocument(sourceDocument, for: proxyMode)
    } catch {
      // 规则快照缺失/损坏：不静默退化成全局（issue #63 AC4）。
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.runtimeFile)
      return false
    }
    lastDocument = document
    guard await execute(.run(document), document: document) else { return false }
    state = .starting
    return await presentLaunchHealth(
      document, requiresReceipt: document.aclRuntime != nil)
  }

  /// D8「任何路径不静默改端口」：监听设置不可读时以占位出厂端口部署等于
  /// 系统擅自改端口——停止运行时并点名呈现，等用户在设置区修复（#33 接线）。
  private func refuseDeployForUnreadableListenSettings() async {
    RuntimeLog.emit(.activationFailed(reason: "listen settings unreadable"))
    _ = await execute(.stop, document: nil)
    lastDocument = nil
    skippedServers = []
    state = .launchFailed(.unreadableSettings)
    await withdrawSystemProxyAfterEntryLoss()
  }

  /// 活动目标失效（issue #60）：清除并持久化 nil，点名原因独立呈现；agent
  /// 继续以空服务器列表监听；系统代理安全撤回（意图保留，条件恢复后自动
  /// 收敛），不悄悄选择其他服务器。
  func handleCleared(_ failure: ActivationFailure) async {
    RuntimeLog.emit(.activationFailed(reason: String(describing: failure)))
    do {
      try activationFileStore.save(activeTargetID: nil)
    } catch {
      // 清目标失败不阻断收敛：下次重同步会再次收敛（目标已不在状态机中）。
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    }
    lastActivationFailure = failure
    skippedServers = []
    await withdrawSystemProxyAfterEntryLoss()
    if settings.agentEnabled {
      await deployListeningWithoutTarget()
    } else {
      // 会话内意图已被关闭的残余：按关闭语义收敛。
      _ = await execute(.stop, document: nil)
      state = .off
      lastDocument = nil
    }
  }
}

// MARK: - 计划动作执行

extension ProxyRuntimeController {
  /// 按计划顺序执行动作；返回 false 表示中途失败、状态已呈现（后续动作与
  /// 健康探测都不应继续）。
  func execute(_ intent: RuntimeIntent, document: SslocalRuntimeDocument?) async -> Bool {
    cancelFirewallObservation()
    flowGeneration += 1
    let actions = ProxyRuntimePlan.actions(
      intent: intent,
      agentStatus: agent.status,
      wrapper: wrapperState(),
      contractOnDisk: runtimeFileStore.readData())
    if case .run = intent, actions.isEmpty {
      RuntimeLog.emit(.contractUnchanged)
    }
    for action in actions {
      guard await perform(action, document: document) else { return false }
    }
    return true
  }

  /// 执行单个动作；返回 false 表示应终止后续动作（状态已呈现）。
  private func perform(_ action: RuntimeAction, document: SslocalRuntimeDocument?) async -> Bool {
    switch action {
    case .writeContract:
      return performWriteContract(document)
    case .registerAgent:
      return performAgentRegistration()
    case .unregisterAgent:
      return await performAgentUnregistration()
    case .signalReload(let pid):
      return performSignalReload(pid)
    case .deleteRuntimeFiles:
      runtimeFileStore.deleteRuntimeFiles()
      RuntimeLog.emit(.runtimeFilesDeleted)
      return true
    }
  }

  /// 原子写契约文件；缺文档或写失败即终止。
  private func performWriteContract(_ document: SslocalRuntimeDocument?) -> Bool {
    guard let document else {
      state = .serviceFailed(.missingDocument)
      return false
    }
    do {
      try runtimeFileStore.write(document)
      RuntimeLog.emit(.contractWritten(serverCount: document.servers.count))
      return true
    } catch {
      state = .serviceFailed(.runtimeFile)
      return false
    }
  }

  /// 注册 LaunchAgent；需用户批准或注册失败即终止并呈现对应状态。
  private func performAgentRegistration() -> Bool {
    do {
      try agent.register()
    } catch {
      RuntimeLog.emit(.agentRegisterFailed(detail: describe(error)))
      if agent.status == .requiresApproval {
        // 注册请求已被系统接收，等待用户在登录项中批准。
        state = .requiresApproval
        return false
      }
      if agent.status != .registered {
        state = .serviceFailed(.agent)
        return false
      }
      // 注册与状态读取之间的竞态：已注册即达意图，不视为失败。
    }
    RuntimeLog.emit(.agentRegistered)
    if agent.status == .requiresApproval {
      state = .requiresApproval
      return false
    }
    return true
  }

  /// 注销 LaunchAgent 并等待 wrapper 退出；未注册竞态可忽略（尽力而为）。
  private func performAgentUnregistration() async -> Bool {
    do {
      try agent.unregister()
    } catch {
      RuntimeLog.emit(.agentUnregisterFailed(detail: describe(error)))
    }
    RuntimeLog.emit(.agentUnregistered)
    await waitForWrapperExit()
    return true
  }

  private func performSignalReload(_ pid: Int32) -> Bool {
    guard sendSignal(pid, SIGUSR1) == 0 else {
      state = .serviceFailed(.agent)
      return false
    }
    return true
  }
}
