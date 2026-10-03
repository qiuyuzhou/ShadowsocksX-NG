import Foundation

extension ProxyRuntimeController {
  /// The choice persists with the settings snapshot. ACL-backed modes (direct
  /// and global) also deploy and verify the ACL runtime even when system proxy
  /// is off, because manually connected SOCKS and HTTP clients use the same ACL.
  func setProxyMode(_ mode: ProxyMode) async {
    guard ProxyMode.availableModes.contains(mode) else { return }
    guard mode != proxyMode else { return }
    await transitionMode(mode, ruleDefaultAction: settings.ruleDefaultAction)
  }

  /// 规则模式子选项（issue #63）：切换「未匹配时代理/直连」并重部署 ACL。
  /// 失败保留旧模式、旧子选项与旧系统代理应用状态。
  func setRuleDefaultAction(_ action: RuleDefaultAction) async {
    guard action != settings.ruleDefaultAction else { return }
    await transitionMode(proxyMode, ruleDefaultAction: action)
  }

  /// 模式切换前的可恢复快照：失败时按它原样还原。
  private struct ModeTransitionSnapshot {
    let settings: ProxySettings
    let mode: ProxyMode
    /// 切换前的运行时文档；无活动文档时为 `nil`，恢复前由调用方补上当次加载值。
    let document: SslocalRuntimeDocument?
    let state: AgentRunState

    /// 用当次加载的文档补齐快照（原 `previousDocument ?? currentDocument` 语义）。
    func resolvingDocument(_ fallback: SslocalRuntimeDocument) -> ModeTransitionSnapshot {
      ModeTransitionSnapshot(
        settings: settings, mode: mode, document: document ?? fallback, state: state)
    }
  }

  private func transitionMode(
    _ mode: ProxyMode,
    ruleDefaultAction: RuleDefaultAction
  ) async {
    let snapshot = ModeTransitionSnapshot(
      settings: settings, mode: proxyMode, document: lastDocument, state: state)
    var next = settings
    next.preferredMode = mode.kind
    next.ruleDefaultAction = ruleDefaultAction
    do {
      try settingsStore.save(next)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.persistence)
      return
    }
    settings = next
    proxyMode = mode
    modeChangeGeneration += 1
    var ticket = convergenceTicket()

    guard settings.agentEnabled, state != .off,
      let currentDocument = lastDocument ?? runtimeFileStore.loadDocument()
    else {
      if settings.systemProxyEnabled { systemProxyState = .pending }
      return
    }

    let nextDocument: SslocalRuntimeDocument
    do {
      nextDocument = try await runtimeDocument(currentDocument, for: mode)
    } catch RulePreparationError.superseded {
      return
    } catch {
      // 快照缺失/损坏：不静默退化，恢复旧模式与旧子选项。
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      ticket.preparation = runtimePreparationGeneration
      await restoreModeTransition(
        snapshot: snapshot.resolvingDocument(currentDocument), ticket: ticket)
      return
    }
    // 派生自身推进了派生代际：票据以派生后的当前值推进 preparation 分量。
    ticket.preparation = runtimePreparationGeneration
    guard nextDocument.aclRuntime != currentDocument.aclRuntime else {
      guard settings.systemProxyEnabled else { return }
      state = .starting
      _ = await presentLaunchHealth(nextDocument)
      return
    }

    await deployModeTransition(
      nextDocument, snapshot: snapshot.resolvingDocument(currentDocument), ticket: ticket)
  }

  enum RulePreparationError: Error { case superseded }

  private struct RulePreparationTicket {
    let generation: Int
    let flow: Int
    let modeGeneration: Int
    let settings: ProxySettings
    let target: NodeID?
    let ruleRevision: Int?
  }

  /// Capture mutable facts before leaving the UI actor. A stale task may not
  /// mutate runtime state or write a contract, even when its calculation fails.
  func runtimeDocument(
    _ source: SslocalRuntimeDocument, for mode: ProxyMode
  ) async throws -> SslocalRuntimeDocument {
    runtimePreparationGeneration += 1
    let ticket = RulePreparationTicket(
      generation: runtimePreparationGeneration, flow: flowGeneration,
      modeGeneration: modeChangeGeneration, settings: settings, target: activeTargetID,
      ruleRevision: mode == .rule ? ruleDocuments.revision : nil)
    do {
      let user = mode == .rule ? try ruleDocuments.load() : nil
      let builtIn =
        mode == .rule ? try await runtimeBuiltinRules(ticket.settings.ruleDefaultAction) : []
      let aclURL = runtimeFileStore.aclFileURL
      let result = await Task.detached(priority: .userInitiated) {
        RuleRuntimeCompiler.compile(
          .init(
            source: source, mode: mode, defaultAction: ticket.settings.ruleDefaultAction,
            document: user, builtIn: builtIn, aclURL: aclURL))
      }.value
      guard preparationIsCurrent(ticket) else { throw RulePreparationError.superseded }
      return result
    } catch {
      guard preparationIsCurrent(ticket) else { throw RulePreparationError.superseded }
      throw error
    }
  }

  private func preparationIsCurrent(_ ticket: RulePreparationTicket) -> Bool {
    ticket.generation == runtimePreparationGeneration && ticket.flow == flowGeneration
      && ticket.modeGeneration == modeChangeGeneration
      && ticket.settings.listen == settings.listen
      && ticket.settings.preferredMode == settings.preferredMode
      && ticket.settings.ruleDefaultAction == settings.ruleDefaultAction
      && ticket.settings.agentEnabled == settings.agentEnabled
      && ticket.target == activeTargetID
      && (ticket.ruleRevision == nil || ticket.ruleRevision == ruleDocuments.revision)
  }

  private func runtimeBuiltinRules(_ action: RuleDefaultAction) async throws -> [ProxyRule] {
    switch action {
    case .proxyWhenUnmatched:
      let geolocation = try await ruleSnapshots.load(.geolocationCN)
      let china = try await ruleSnapshots.load(.chinaIPv4)
      return await Task.detached(priority: .userInitiated) {
        BuiltinRuleCatalog.chinaDirectRules(from: [geolocation, china])
      }.value
    case .directWhenUnmatched:
      let snapshot = try await ruleSnapshots.load(.gfwlist)
      return await Task.detached(priority: .userInitiated) {
        BuiltinRuleCatalog.gfwlistRules(from: snapshot)
      }.value
    }
  }

  func ruleModeCandidateRules() async throws -> [ProxyRule] {
    try await ruleModeValidation().accepted
  }

  func ruleModeValidation() async throws -> CustomRuleValidationResult {
    let document = try ruleDocuments.load()
    let action = settings.ruleDefaultAction
    let builtIn = try await runtimeBuiltinRules(action)
    return await Task.detached(priority: .userInitiated) {
      RuleRuntimeCompiler.validation(document: document, builtIn: builtIn, defaultAction: action)
    }.value
  }

  private func deployModeTransition(
    _ document: SslocalRuntimeDocument,
    snapshot: ModeTransitionSnapshot,
    ticket: ConvergenceTicket
  ) async {
    var ticket = ticket
    // 两个调用点都经 resolvingDocument 补齐文档；防御性解包失败即无事可做。
    guard let rollbackDocument = snapshot.document else { return }
    let plan = RollbackPlan(
      document: rollbackDocument, state: snapshot.state,
      payload: .modeTransition(
        mode: snapshot.mode, ruleDefaultAction: snapshot.settings.ruleDefaultAction),
      systemProxyIntentAtCapture: snapshot.settings.systemProxyEnabled,
      convergeProxyOnIntentChange: true)
    let result = await apply(
      document, ticket: &ticket, checking: [.mode, .preparation],
      requiresReceipt: true,
      convergeProxyOnSuccess: false,
      preserveProxyOnFailure: true,
      proxyTail: .forceApply, rollback: plan)
    if case .failed = result {
      await restoreModeTransition(snapshot: snapshot, ticket: ticket)
    }
  }

  /// mode 切换的失败回滚：按快照整体恢复；载荷持久化失败以 serviceFailed
  /// 呈现（仅在旧运行时恢复到健康时）。
  private func restoreModeTransition(
    snapshot: ModeTransitionSnapshot,
    ticket: ConvergenceTicket
  ) async {
    var ticket = ticket
    guard let previousDocument = snapshot.document else { return }
    let plan = RollbackPlan(
      document: previousDocument, state: snapshot.state,
      payload: .modeTransition(
        mode: snapshot.mode, ruleDefaultAction: snapshot.settings.ruleDefaultAction),
      systemProxyIntentAtCapture: snapshot.settings.systemProxyEnabled,
      convergeProxyOnIntentChange: true)
    let report = await restore(plan, ticket: &ticket, checking: [.mode, .preparation])
    if report.runtimeHealthy == true, report.payloadFailureDescription != nil {
      state = .serviceFailed(.persistence)
    }
  }
}
