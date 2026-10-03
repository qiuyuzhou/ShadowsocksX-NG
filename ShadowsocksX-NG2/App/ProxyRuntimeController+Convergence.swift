import Foundation

/// 一次计划执行的结果:动作是否全部按序成功,以及本次执行占用的并发流
/// 代际。占用代际供收敛票据推进 flow 分量,取代调用方对 execute 内部
/// 「恰好自增一次」时序的依赖(原 `flowGeneration + 1` 手算)。
struct RuntimeExecutionOutcome {
  /// 本次执行占用的 `flowGeneration`。
  let flow: Int
  /// 全部计划动作是否按序成功。
  let succeeded: Bool
}

/// 收敛票据:运行时收敛操作的代际快照。入口捕获三个并发代际,之后每步
/// 推进用它判定「从入口到现在,并发流 / 模式切换 / 运行时派生是否前进了」;
/// 被更新提交或新意图取代的旧收敛不得再变更运行时状态或写契约。
///
/// 各路径校验的代际子集不同:mode 切换的 mode 代际在派生前捕获、派生
/// 代际在派生后推进(派生自身会推进它);rules 部署四个事实全查(含
/// 会话内 agent 意图);目录 / 启动路径只查派生代际。
struct ConvergenceTicket: Equatable {
  /// 票据时效校验覆盖的代际事实子集。
  struct Checks: OptionSet {
    let rawValue: Int
    /// 并发流代际:任何后续 execute 都使票据失效。
    static let flow = Checks(rawValue: 1 << 0)
    /// 模式切换代际。
    static let mode = Checks(rawValue: 1 << 1)
    /// 运行时文档派生代际。
    static let preparation = Checks(rawValue: 1 << 2)
    /// 会话内 agent 意图仍开启。
    static let agentEnabled = Checks(rawValue: 1 << 3)
  }

  /// 并发流代际;每次 execute 之后由调用方以实际占用值推进。
  var flow: Int
  /// 模式切换代际;捕获后不再变化。
  let mode: Int
  /// 运行时文档派生代际;每次派生之后由调用方以当前值推进。
  var preparation: Int
}

extension ProxyRuntimeController {
  /// 以当前代际捕获收敛票据。
  func convergenceTicket() -> ConvergenceTicket {
    ConvergenceTicket(
      flow: flowGeneration, mode: modeChangeGeneration,
      preparation: runtimePreparationGeneration)
  }

  /// 票据是否仍代表当前收敛:`checking` 列出的代际事实全部未前进。
  func convergenceIsCurrent(
    _ ticket: ConvergenceTicket, checking: ConvergenceTicket.Checks
  ) -> Bool {
    var current = true
    if checking.contains(.flow) { current = current && ticket.flow == flowGeneration }
    if checking.contains(.mode) { current = current && ticket.mode == modeChangeGeneration }
    if checking.contains(.preparation) {
      current = current && ticket.preparation == runtimePreparationGeneration
    }
    if checking.contains(.agentEnabled) { current = current && settings.agentEnabled }
    return current
  }

  /// 派生文档对当前运行时是否无事可做（CONTEXT.md「有效值未变的提交不做
  /// 运行时收敛」）：磁盘契约与派生字节逐位相同、agent 已注册且 wrapper
  /// 存活、控制器处于健康运行态——计划层动作序列为空即幂等跳过。判定在
  /// 置 `starting` 之前进行，跳过路径不闪状态、不重走健康门；磁盘漂移或
  /// wrapper 失踪时动作序列自然非空，走完整 deploy 自愈。
  func convergencePlanIsEmpty(
    _ document: SslocalRuntimeDocument, preparedContract: PreparedRuntimeContract?
  ) -> Bool {
    switch state {
    case .running, .firewallBlocked:
      break
    case .off, .starting, .launchFailed, .requiresApproval, .serviceFailed:
      return false
    }
    let actions = ProxyRuntimePlan.actions(
      intent: .run(document),
      agentStatus: agent.status,
      wrapper: wrapperState(),
      contractOnDisk: runtimeFileStore.readData(), preparedContract: preparedContract)
    return actions.isEmpty
  }

  /// 统一的设置持久化 epilogue：保存失败不静默偏离持久化事实——记录日志、
  /// 呈现 `serviceFailed(.persistence)`，调用方放弃本次收敛。
  func persistSettings(_ proposed: ProxySettings) -> Bool {
    do {
      try settingsStore.save(proposed)
      return true
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.persistence)
      return false
    }
  }

  /// reexpand 三-case 开关的收敛主体（显式收敛、设置保存、启动重同步共用）：
  /// deployed → 部署派生文档；目标失效 → 清除并按意图收敛；无目标 → 空监听。
  /// 幂等跳过由 apply 层的 plan 空判定承担；目录重校验（跳过名单、目标失效
  /// 清除）已在 `reexpand` 完成，不受其影响。
  func convergeToReexpanded(_ catalog: ConfigurationCatalog) async {
    switch reexpand(in: catalog) {
    case .deployed(let configuration):
      await deploy(configuration.document)
    case .clearedAndStopped(let failure):
      await handleCleared(failure)
    case nil:
      await deployListeningWithoutTarget()
    }
  }

  /// 收敛脊柱 apply 层的结果。
  enum ConvergenceResult {
    /// 部署已执行且启动健康通过。
    case applied
    /// 派生契约与运行中运行时逐字节相同：不写契约、不发信号、不闪
    /// starting、不重走健康门与系统代理收敛（幂等跳过）。
    case unchanged
    /// 执行或健康门失败；回滚由调用方按 RollbackPlan 处理。
    case failed
    /// 被更新的收敛取代：不得再变更任何状态。
    case superseded
  }

  /// 成功收敛后的系统代理收尾方式。
  enum ProxyConvergenceTail {
    /// 强制重收敛（mode 切换：系统代理值随模式 ACL 变化）。
    case forceApply
    /// 常规收敛（rules 提交）。
    case converge
    /// 无需收尾（deploy 路径由健康门自身的 convergeProxyOnSuccess 收敛）。
    case none
  }

  /// 收敛脊柱 apply 层：把一个已派生的运行时定义推到运行时——幂等跳过、
  /// 计划执行、启动健康门、成功后按参数收敛系统代理。失败不在此回滚：
  /// 返回 `.failed` 由调用方按 RollbackPlan 整体恢复。
  ///
  /// 票据 inout 传参：execute / 派生后的代际推进对调用方可见，调用方
  /// 在 apply 之后的时效检查使用的是推进过的票据。
  ///
  /// `starting` 在 execute 之前置位：`.run` 计划的动作全部同步执行，二者
  /// 之间不存在可见的挂起点，与旧路径「deploy 后置位」不可区分。
  func apply(
    _ document: SslocalRuntimeDocument,
    ticket: inout ConvergenceTicket,
    checking: ConvergenceTicket.Checks,
    requiresReceipt: Bool,
    convergeProxyOnSuccess: Bool,
    preserveProxyOnFailure: Bool,
    proxyTail: ProxyConvergenceTail,
    rollback: RollbackPlan?
  ) async -> ConvergenceResult {
    let contract = try? PreparedRuntimeContract(document)
    if convergencePlanIsEmpty(document, preparedContract: contract) {
      RuntimeLog.emit(.contractUnchanged)
      return .unchanged
    }
    guard convergenceIsCurrent(ticket, checking: checking) else { return .superseded }
    lastDocument = document
    state = .starting
    let execution = await execute(.run(document), document: document, preparedContract: contract)
    ticket.flow = execution.flow
    guard convergenceIsCurrent(ticket, checking: checking) else { return .superseded }
    guard execution.succeeded else { return .failed }
    let healthy = await presentLaunchHealth(
      document,
      requiresReceipt: requiresReceipt,
      convergeProxyOnSuccess: convergeProxyOnSuccess,
      preserveProxyOnFailure: preserveProxyOnFailure, preparedContract: contract)
    guard convergenceIsCurrent(ticket, checking: checking) else { return .superseded }
    guard healthy else { return .failed }
    lastDocument = document
    switch proxyTail {
    case .forceApply: await systemProxyObserver.convergeSystemProxy(forceApply: true)
    case .converge: await systemProxyObserver.convergeSystemProxy()
    case .none: break
    }
    return .applied
  }

  /// 按回滚计划整体恢复：重持久化载荷 → 计划执行拉回旧文档（含按需拉起，
  /// 由计划层对注销/信号/注册的裁决保证与旧 restore 例程等价）→ 启动健康
  /// 门。载荷持久化失败不阻断文档恢复；文档恢复失败或健康不过即撤下系统
  /// 代理意图。
  func restore(
    _ plan: RollbackPlan, ticket: inout ConvergenceTicket,
    checking: ConvergenceTicket.Checks
  ) async -> RestoreReport {
    var payloadFailureDescription: String?
    var restoredSettingsForMemory: ProxySettings?
    var restoredMode: ProxyMode?
    switch plan.payload {
    case .modeTransition(let mode, let ruleDefaultAction):
      // 按快照还原偏好（模式与子选项回退，其余字段保留当前值）。
      var restored = settings
      restored.preferredMode = mode.kind
      restored.ruleDefaultAction = ruleDefaultAction
      do {
        try settingsStore.save(restored)
      } catch {
        payloadFailureDescription = String(describing: error)
        RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      }
      restoredSettingsForMemory = restored
      restoredMode = mode
    case .customRules(let document):
      do {
        try ruleDocuments.save(document)
      } catch {
        payloadFailureDescription = String(describing: error)
        RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      }
    }
    func report(_ healthy: Bool?) -> RestoreReport {
      RestoreReport(
        payloadFailureDescription: payloadFailureDescription, runtimeHealthy: healthy)
    }
    if checking.contains(.agentEnabled), !settings.agentEnabled { return report(nil) }
    guard convergenceIsCurrent(ticket, checking: checking) else { return report(nil) }
    if let restoredSettingsForMemory { settings = restoredSettingsForMemory }
    if let restoredMode { proxyMode = restoredMode }
    lastDocument = plan.document
    state = .starting
    let contract = try? PreparedRuntimeContract(plan.document)
    let execution = await execute(
      .run(plan.document), document: plan.document, preparedContract: contract)
    ticket.flow = execution.flow
    guard convergenceIsCurrent(ticket, checking: checking) else { return report(nil) }
    guard execution.succeeded else {
      await systemProxyObserver.holdSystemProxyIntent()
      return report(false)
    }
    let healthy = await presentLaunchHealth(
      plan.document, requiresReceipt: true, convergeProxyOnSuccess: false,
      preparedContract: contract)
    guard convergenceIsCurrent(ticket, checking: checking) else { return report(nil) }
    if healthy {
      if plan.convergeProxyOnIntentChange,
        settings.systemProxyEnabled != plan.systemProxyIntentAtCapture
      {
        await systemProxyObserver.convergeSystemProxy(forceApply: true)
      } else {
        state = plan.state
      }
    } else {
      await systemProxyObserver.holdSystemProxyIntent()
    }
    return report(healthy)
  }
}

/// 收敛失败时的整体回滚计划：恢复到哪个运行时文档、健康通过后呈现哪个
/// 状态、以及除文档外还要重持久化的载荷。
struct RollbackPlan {
  /// 回滚载荷：除运行时文档外还要恢复的持久化事实。
  enum Payload {
    /// mode 切换：设置快照的模式与规则子选项回退（其余字段保留当前值），
    /// 会话内 proxyMode 一并还原。
    case modeTransition(mode: ProxyMode, ruleDefaultAction: RuleDefaultAction)
    /// rules 提交：恢复规则文档。
    case customRules(CustomRuleDocument)
  }

  /// 回滚目标文档（调用方已用当次加载值补齐）。
  let document: SslocalRuntimeDocument
  /// 健康通过后呈现的状态（收敛开始前捕获）。
  let state: ProxyRuntimeController.AgentRunState
  let payload: Payload
  /// 捕获时的系统代理意图：恢复健康后若当前意图已变化，强制重收敛一次。
  let systemProxyIntentAtCapture: Bool
  /// 是否在意图变化时强制重收敛（mode 切换路径；rules 路径为 false）。
  let convergeProxyOnIntentChange: Bool
}

/// 回滚报告：载荷重持久化与旧运行时恢复的结果。
struct RestoreReport {
  /// 载荷持久化失败的点名描述；nil = 成功。
  let payloadFailureDescription: String?
  /// 旧运行时是否恢复到健康；nil = 恢复未尝试（被弃权或被取代）。
  let runtimeHealthy: Bool?
}
