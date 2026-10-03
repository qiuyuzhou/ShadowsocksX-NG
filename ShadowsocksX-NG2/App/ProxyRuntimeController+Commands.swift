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

  /// Agent 开关（issue #60/#71）：先持久化意图（显式关闭在 GUI 重启后仍生效），
  /// 再收敛运行时。持久化失败保留现状并点名，不静默偏离持久化事实。意图已
  /// 开启时的开启命令仅在未达健康态时重收敛——它是启动失败/重置后的显式
  /// 重试入口；健康运行中不做无谓的注销重拉。关闭时级联：系统代理意图仍
  /// 开启则一并持久化为关闭，该 on→off 迁移触发清理，清理后才停止本地监听；
  /// 系统代理意图本就关闭则不做任何系统设置操作。
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
    guard persistSettings(next) else { return }
    settings = next
    if enabled {
      await convergeAgent()
      if settings.systemProxyEnabled { systemProxyObserver.startEnabledSystemProxyObservation() }
    } else {
      let cleanupOutcome = await cascadeSystemProxyOffForAgentOff()
      await stopAgent()
      if let cleanupOutcome, cleanupOutcome.hasOperationFailure {
        systemProxyObserver.systemProxyState = cleanupOutcome
      }
      systemProxyObserver.updateSystemProxyActions()
    }
  }

  /// 关闭 agent 时的系统代理级联（issue #71）：意图仍开启则一并持久化为
  /// 关闭并请求清理（返回清理结果）；级联持久化失败时迁移未被记录，不清理
  /// （story 13），意图与系统设置原样，返回 nil。
  private func cascadeSystemProxyOffForAgentOff() async -> SystemProxyControlState? {
    guard settings.systemProxyEnabled else { return nil }
    var cascade = settings
    cascade.systemProxyEnabled = false
    do {
      try settingsStore.save(cascade)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      return nil
    }
    settings = cascade
    // 持久化的 on→off 迁移才触发清理；先清后停本地监听。
    return await systemProxyObserver.clearAndStopSystemProxyObservation()
  }

  /// 系统代理开关（issue #71）：先持久化意图。开启时经 helper 注册门禁收敛
  /// 应用；关闭即一次 on→off 意图迁移——请求一次无条件清理（临时观察网络
  /// 变化直至安静，失败也不后台重试），不影响 agent 注册与本地监听。
  func setSystemProxyEnabled(_ enabled: Bool) async {
    guard enabled != settings.systemProxyEnabled else { return }
    var next = settings
    next.systemProxyEnabled = enabled
    guard persistSettings(next) else { return }
    settings = next
    if enabled {
      systemProxyObserver.systemProxyInitialApplyPending = true
      systemProxyObserver.systemProxyWasUnavailable = false
      await systemProxyObserver.convergeSystemProxy()
      systemProxyObserver.startEnabledSystemProxyObservation()
    } else {
      systemProxyObserver.systemProxyApprovalRequired = false
      systemProxyObserver.systemProxyInitialApplyPending = false
      systemProxyObserver.systemProxyReadGeneration += 1
      systemProxyObserver.systemProxyState =
        await systemProxyObserver.clearAndStopSystemProxyObservation()
      systemProxyObserver.updateSystemProxyActions()
    }
  }

  /// GUI startup restores the Agent. Healthy proxy intent only inspects; unhealthy
  /// proxy intent suspends; disabled intent never writes SystemConfiguration.
  func resyncOnLaunch() async {
    systemProxyObserver.systemProxyStartupInProgress = true
    guard settings.agentEnabled else {
      await stopAgent()
      systemProxyObserver.systemProxyStartupInProgress = false
      if settings.systemProxyEnabled {
        await systemProxyObserver.suspendSystemProxy()
        systemProxyObserver.startEnabledSystemProxyObservation()
      }
      return
    }
    let catalog = catalogSnapshotReader.catalogSnapshot
    await convergeToReexpanded(catalog)
    systemProxyObserver.systemProxyStartupInProgress = false
    if settings.systemProxyEnabled {
      systemProxyObserver.lastDesiredSystemProxyConfiguration = desiredSystemProxyConfiguration
      if systemProxyExitAvailable {
        await systemProxyObserver.recheckSystemProxy()
      } else {
        await systemProxyObserver.suspendSystemProxy()
      }
      systemProxyObserver.startEnabledSystemProxyObservation()
    } else {
      systemProxyObserver.systemProxyState = .idle
    }
  }

  // MARK: - 动作执行

  /// Agent 意图开启的收敛：注册态不是事实来源，意图才是——未注册也会注册，
  /// 已注册则重校验目标并部署。偏好重置后也走此路径，把运行时收敛到出厂设置。
  func convergeAgent() async {
    await convergeToReexpanded(catalogSnapshotReader.catalogSnapshot)
  }

  /// Agent 意图关闭的收敛（issue #71）：只停止本地监听，不做系统代理清理。
  /// 系统代理状态按意图事实收尾——级联后意图已关闭为空闲；残留的「意图开
  /// 启 + agent 关闭」组合保持待应用（不静默清理，也无需网络观察）。
  func stopAgent() async {
    systemProxyNetworkChangeMonitor.stop()
    systemProxyObserver.systemProxyHealthTask?.cancel()
    systemProxyObserver.systemProxyHealthTask = nil
    systemProxyObserver.systemProxyObservationMode = .stopped
    _ = await execute(.stop, document: nil)
    state = .off
    lastDocument = nil
    skippedServers = []
    lastActivationFailure = nil
    if settings.systemProxyEnabled {
      systemProxyObserver.systemProxyState = .pending
    } else {
      if !systemProxyState.hasOperationFailure {
        systemProxyObserver.systemProxyState = .idle
      }
      systemProxyObserver.updateSystemProxyActions()
    }
  }

  /// 无活动目标时 agent 仍提供本地监听（issue #60）：空服务器列表文档，
  /// SOCKS/HTTP 端点照常绑定；系统代理门禁会因缺少可用出口保持待应用。
  func deployListeningWithoutTarget() async {
    let document = SslocalRuntimeDocument(
      servers: [],
      listen: settings.listen)
    await deploy(document)
  }

  /// 把「运行定义档」意图推到运行时：派生文档 → 收敛脊柱 apply（幂等跳过、
  /// 计划执行、健康门）。
  @discardableResult
  func deploy(_ sourceDocument: SslocalRuntimeDocument) async -> ConvergenceResult {
    if listenSettingsUnreadable || settingsUnreadable {
      await refuseDeployForUnreadableListenSettings()
      return .failed
    }
    let contract: PreparedRuntimeContract
    do {
      contract = try PreparedRuntimeContract(await runtimeDocument(sourceDocument, for: proxyMode))
    } catch RulePreparationError.superseded {
      return .superseded
    } catch {
      // 规则快照缺失/损坏：不静默退化成全局（issue #63 AC4）。
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.runtimeFile)
      return .failed
    }
    return await deployPrepared(contract, preparation: runtimePreparationGeneration)
  }

  @discardableResult
  func deployPrepared(
    _ contract: PreparedRuntimeContract, preparation: Int
  ) async -> ConvergenceResult {
    guard preparation == runtimePreparationGeneration else { return .superseded }
    let document = contract.document
    var ticket = convergenceTicket()
    return await apply(
      document, ticket: &ticket, checking: [.preparation],
      requiresReceipt: document.aclRuntime != nil,
      convergeProxyOnSuccess: true,
      preserveProxyOnFailure: false,
      proxyTail: .none, rollback: nil)
  }

  /// D8「任何路径不静默改端口」：监听设置不可读时以占位出厂端口部署等于
  /// 系统擅自改端口——停止运行时并点名呈现，等用户在设置区修复（#33 接线）。
  private func refuseDeployForUnreadableListenSettings() async {
    RuntimeLog.emit(.activationFailed(reason: "listen settings unreadable"))
    _ = await execute(.stop, document: nil)
    lastDocument = nil
    skippedServers = []
    state = .launchFailed(.unreadableSettings)
    await systemProxyObserver.holdSystemProxyIntent()
  }

  /// 活动目标失效（issue #60）：清除并持久化 nil，点名原因独立呈现；agent
  /// 继续以空服务器列表监听；系统代理清理后保留意图，条件恢复后自动
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
    await systemProxyObserver.holdSystemProxyIntent()
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
  /// 把「运行定义档」意图推到运行时：计划动作 → 顺序执行。返回全部动作
  /// 是否成功与本次占用的并发流代际。
  func execute(
    _ intent: RuntimeIntent, document: SslocalRuntimeDocument?,
    preparedContract: PreparedRuntimeContract? = nil
  ) async -> RuntimeExecutionOutcome {
    cancelFirewallObservation()
    flowGeneration += 1
    let flow = flowGeneration
    let succeeded = await performPlannedActions(
      intent, document: document, preparedContract: preparedContract, flow: flow)
    return RuntimeExecutionOutcome(flow: flow, succeeded: succeeded)
  }

  /// 按计划顺序执行动作；返回 false 表示中途失败、状态已呈现（后续动作与
  /// 健康探测都不应继续）。
  private func performPlannedActions(
    _ intent: RuntimeIntent, document: SslocalRuntimeDocument?,
    preparedContract: PreparedRuntimeContract?, flow: Int
  ) async -> Bool {
    let preparation = runtimePreparationGeneration
    let contract: PreparedRuntimeContract?
    if case .run(let desired) = intent {
      guard let prepared = preparedContract ?? (try? PreparedRuntimeContract(desired)),
        prepared.document == desired, document == desired
      else {
        state = .serviceFailed(document == nil ? .missingDocument : .runtimeFile)
        return false
      }
      contract = prepared
    } else {
      contract = nil
    }
    let actions = ProxyRuntimePlan.actions(
      intent: intent,
      agentStatus: agent.status,
      wrapper: wrapperState(),
      contractOnDisk: runtimeFileStore.readData(), preparedContract: contract)
    if case .run = intent, actions.isEmpty {
      RuntimeLog.emit(.contractUnchanged)
    }
    for action in actions {
      guard flow == flowGeneration, preparation == runtimePreparationGeneration,
        await perform(action, preparedContract: contract)
      else { return false }
    }
    return flow == flowGeneration && preparation == runtimePreparationGeneration
  }

  /// 执行单个动作；返回 false 表示应终止后续动作（状态已呈现）。
  private func perform(
    _ action: RuntimeAction, preparedContract: PreparedRuntimeContract?
  ) async -> Bool {
    switch action {
    case .writeContract:
      return performWriteContract(preparedContract)
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
  private func performWriteContract(_ contract: PreparedRuntimeContract?) -> Bool {
    guard let contract else {
      state = .serviceFailed(.missingDocument)
      return false
    }
    do {
      try runtimeFileStore.write(contract)
      RuntimeLog.emit(.contractWritten(serverCount: contract.document.servers.count))
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
