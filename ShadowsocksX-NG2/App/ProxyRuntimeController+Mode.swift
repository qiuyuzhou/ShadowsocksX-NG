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
    let generation = modeChangeGeneration

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
      await restoreModeTransition(
        snapshot: snapshot.resolvingDocument(currentDocument), generation: generation)
      return
    }
    guard nextDocument.aclRuntime != currentDocument.aclRuntime else {
      guard settings.systemProxyEnabled else { return }
      state = .starting
      _ = await presentLaunchHealth(nextDocument)
      return
    }

    await deployModeTransition(
      nextDocument, snapshot: snapshot.resolvingDocument(currentDocument),
      generation: generation, preparation: runtimePreparationGeneration)
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
    generation: Int, preparation: Int
  ) async {
    guard generation == modeChangeGeneration, preparation == runtimePreparationGeneration else {
      return
    }
    let contract = try? PreparedRuntimeContract(document)
    lastDocument = document
    state = .starting
    guard await execute(.run(document), document: document, preparedContract: contract) else {
      guard generation == modeChangeGeneration, preparation == runtimePreparationGeneration else {
        return
      }
      await restoreModeTransition(snapshot: snapshot, generation: generation)
      return
    }

    guard generation == modeChangeGeneration, preparation == runtimePreparationGeneration else {
      return
    }
    let healthy = await presentLaunchHealth(
      document,
      requiresReceipt: true,
      convergeProxyOnSuccess: false,
      preserveProxyOnFailure: true, preparedContract: contract)
    guard generation == modeChangeGeneration, preparation == runtimePreparationGeneration else {
      return
    }
    guard healthy else {
      await restoreModeTransition(snapshot: snapshot, generation: generation)
      return
    }

    lastDocument = document
    await convergeSystemProxy(forceApply: true)
  }

  private func restoreModeTransition(
    snapshot: ModeTransitionSnapshot,
    generation: Int
  ) async {
    let preparation = runtimePreparationGeneration
    // 两个调用点都经 resolvingDocument 补齐文档；防御性解包失败即无事可做。
    guard let previousDocument = snapshot.document else { return }
    let restoredSettings = restoredSettings(for: snapshot)
    var persistenceFailed = false
    do {
      try settingsStore.save(restoredSettings)
    } catch {
      persistenceFailed = true
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    }
    guard generation == modeChangeGeneration, preparation == runtimePreparationGeneration else {
      return
    }
    settings = restoredSettings
    proxyMode = snapshot.mode
    lastDocument = previousDocument

    let contract = try? PreparedRuntimeContract(previousDocument)
    guard
      await restoreRuntimeDocument(
        previousDocument, generation: generation, preparedContract: contract)
    else { return }

    guard generation == modeChangeGeneration, preparation == runtimePreparationGeneration else {
      return
    }
    state = .starting
    let restored = await presentLaunchHealth(
      previousDocument,
      requiresReceipt: true,
      convergeProxyOnSuccess: false, preparedContract: contract)
    guard generation == modeChangeGeneration, preparation == runtimePreparationGeneration else {
      return
    }
    guard restored else {
      await holdSystemProxyIntent()
      return
    }

    if settings.systemProxyEnabled != snapshot.settings.systemProxyEnabled {
      await convergeSystemProxy(forceApply: true)
    } else {
      state = snapshot.state
    }
    if persistenceFailed { state = .serviceFailed(.persistence) }
  }

  /// 按快照还原偏好（模式与子选项回退，其余字段保留当前值）。
  private func restoredSettings(for snapshot: ModeTransitionSnapshot) -> ProxySettings {
    var restored = settings
    restored.preferredMode = snapshot.mode.kind
    restored.ruleDefaultAction = snapshot.settings.ruleDefaultAction
    return restored
  }

  /// 把运行时文件与包装进程恢复到旧文档；文件写入或进程拉起失败即撤下系统
  /// 代理并返回 false（健康检查由调用方继续）。
  private func restoreRuntimeDocument(
    _ previousDocument: SslocalRuntimeDocument,
    generation: Int, preparedContract: PreparedRuntimeContract?
  ) async -> Bool {
    let expectedDigest = preparedContract?.sha256 ?? previousDocument.deploymentSHA256
    let currentDocument = runtimeFileStore.loadDocument()
    let receipt = runtimeFileStore.readRuntimeReceipt()
    let wrapper = wrapperState()
    let previousInstanceIsRunning: Bool
    switch wrapper {
    case .running(let pid):
      previousInstanceIsRunning =
        receipt?.processID == pid && receipt?.contractSHA256 == expectedDigest
    case .notRunning:
      previousInstanceIsRunning = false
    }
    if currentDocument != previousDocument || !previousInstanceIsRunning {
      if currentDocument != previousDocument {
        do {
          if let preparedContract {
            try runtimeFileStore.write(preparedContract)
          } else {
            try runtimeFileStore.write(previousDocument)
          }
        } catch {
          state = .serviceFailed(.runtimeFile)
          await holdSystemProxyIntent()
          return false
        }
      }
      if !previousInstanceIsRunning {
        guard
          await relaunchPreviousInstance(
            wrapper: wrapper, previousDocument: previousDocument, generation: generation,
            preparedContract: preparedContract)
        else { return false }
      }
    }
    return true
  }

  /// 旧实例未在运行时按需拉起：在跑的 wrapper 用 SIGUSR1 唤醒重读，否则重新执行。
  private func relaunchPreviousInstance(
    wrapper: WrapperProcessState,
    previousDocument: SslocalRuntimeDocument,
    generation: Int, preparedContract: PreparedRuntimeContract?
  ) async -> Bool {
    let preparation = runtimePreparationGeneration
    switch wrapper {
    case .running(let pid):
      guard sendSignal(pid, SIGUSR1) == 0 else {
        state = .serviceFailed(.agent)
        await holdSystemProxyIntent()
        return false
      }
    case .notRunning:
      guard
        await execute(
          .run(previousDocument), document: previousDocument,
          preparedContract: preparedContract)
      else {
        guard generation == modeChangeGeneration, preparation == runtimePreparationGeneration else {
          return false
        }
        await holdSystemProxyIntent()
        return false
      }
    }
    return true
  }
}
