import Foundation

// MARK: - 设置变更与目录提交同步

extension ProxyRuntimeController {
  /// 目录提交协调器的生产适配入口（issue #40）：以刚提交的内存快照重展开，
  /// 不回读磁盘（磁盘仍是重启与跨进程恢复的权威来源）。agent 意图开启时
  /// 原子更新运行时；目标失效 → 清除目标但 agent 继续监听。返回结构化收敛
  /// 结果，健康检查耗时属于本调用的异步收敛阶段，不改变「目录已提交」的事实。
  func catalogDidCommit(snapshot catalog: ConfigurationCatalog) async -> RuntimeSyncOutcome {
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      guard settings.agentEnabled else {
        return .revalidated
      }
      if runtimeAlreadyConverged(with: configuration.document) {
        RuntimeLog.emit(.contractUnchanged)
        return Self.syncOutcome(
          agentState: state, systemProxyState: systemProxyState,
          skippedServers: configuration.skippedServers)
      }
      await deploy(configuration.document)
      return Self.syncOutcome(
        agentState: state, systemProxyState: systemProxyState,
        skippedServers: configuration.skippedServers)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
      return .clearedAndStopped(failure)
    case nil:
      guard settings.agentEnabled else {
        return .revalidated
      }
      // 无活动目标：已在以空列表监听则不重走健康门（目录提交不该让状态闪回
      // starting）；否则补齐空监听。
      if state != .off, lastDocument?.servers.isEmpty == true {
        return Self.syncOutcome(
          agentState: state, systemProxyState: systemProxyState, skippedServers: [])
      }
      await deployListeningWithoutTarget()
      return Self.syncOutcome(
        agentState: state, systemProxyState: systemProxyState, skippedServers: [])
    }
  }

  /// 目录提交去抖（CONTEXT.md「有效值未变的提交不做运行时收敛」）：派生文档
  /// （含模式/ACL 合并）与磁盘契约逐字节相等、agent 已注册且 wrapper 存活、
  /// 控制器处于健康运行态时，本次提交对运行时无事可做——不写契约、不发信号、
  /// 不闪 starting、不重走健康门与系统代理收敛。判定复用计划层语义
  /// （`ProxyRuntimePlan.actions` 返回空 = 幂等跳过）：磁盘漂移或 wrapper 失踪
  /// 时动作序列自然非空，走完整 deploy 自愈。目录重校验（跳过名单、目标失效
  /// 清除）已在 `reexpand` 完成，不受此门影响。
  private func runtimeAlreadyConverged(with sourceDocument: SslocalRuntimeDocument) -> Bool {
    switch state {
    case .running, .firewallBlocked:
      break
    case .off, .starting, .launchFailed, .requiresApproval, .serviceFailed:
      return false
    }
    let document: SslocalRuntimeDocument
    do {
      document = try runtimeDocument(sourceDocument, for: proxyMode)
    } catch {
      // 规则快照缺失/损坏：交完整 deploy 如实呈现，不静默当作已收敛。
      return false
    }
    let actions = ProxyRuntimePlan.actions(
      intent: .run(document),
      agentStatus: agent.status,
      wrapper: wrapperState(),
      contractOnDisk: runtimeFileStore.readData())
    return actions.isEmpty
  }

  /// 部署后的控制器状态 → 结构化收敛结果：健康通过（含防火墙受阻的运行态）
  /// 视为已收敛；系统代理写入失败携带点名细节，待应用不算目录收敛失败。
  private static func syncOutcome(
    agentState: AgentRunState, systemProxyState: SystemProxyControlState,
    skippedServers: [SkippedServer]
  ) -> RuntimeSyncOutcome {
    if case .failed(let facts) = systemProxyState {
      return .failed(failure: .systemProxy(facts))
    }
    switch agentState {
    case .running, .firewallBlocked:
      return .converged(skippedServers: skippedServers)
    case .launchFailed(let facts):
      return .failed(failure: .launch(facts))
    case .serviceFailed(let facts):
      return .failed(failure: .service(facts))
    case .requiresApproval, .off, .starting:
      return .failed(failure: nil)
    }
  }

  /// Persists a fully validated settings snapshot and, when the agent is
  /// running, re-derives the same runtime path with the new snapshot. Runtime
  /// status remains observable through the controller's status stream.
  func updateSettings(_ proposed: ProxySettings) async throws {
    let catalog = catalogSnapshotReader.catalogSnapshot
    try settingsStore.save(proposed)
    settings = proposed
    listenSettingsUnreadable = false
    settingsUnreadable = false
    guard state != .off else { return }
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      await deploy(configuration.document)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
    case nil:
      await deployListeningWithoutTarget()
    }
  }

  /// Applies the post-import 2.0 runtime boundary without touching
  /// SystemConfiguration. Importing data leaves the user's system proxy
  /// dictionary untouched; any currently running 2.0 runtime is stopped and
  /// the existing 2.0 target/settings are reloaded.
  func legacyImportDidCommit() async {
    cancelFirewallObservation()
    flowGeneration += 1
    _ = await execute(.stop, document: nil)
    state = .off
    lastDocument = nil
    skippedServers = []
    lastActivationFailure = nil
    // 导入边界不触碰 SystemConfiguration（既有不变量），系统代理状态面同
    // 样不动：它呈现的是系统设置的真实作用，不由导入改写。

    if let restored = try? settingsStore.load() {
      settings = restored
      settingsUnreadable = false
      listenSettingsUnreadable = false
      proxyMode = Self.makeProxyMode(from: restored)
    }
    let persistedTarget = try? activationFileStore.loadActiveTargetID()
    machine = ActivationStateMachine(activeTargetID: persistedTarget ?? nil)
    activeTargetID = machine.activeTargetID
  }
}
