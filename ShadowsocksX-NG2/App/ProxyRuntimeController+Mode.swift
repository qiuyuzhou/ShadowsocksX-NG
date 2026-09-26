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

  private func transitionMode(
    _ mode: ProxyMode,
    ruleDefaultAction: RuleDefaultAction
  ) async {
    let previousSettings = settings
    let previousMode = proxyMode
    let previousDocument = lastDocument
    let previousState = state
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
      nextDocument = try runtimeDocument(currentDocument, for: mode)
    } catch {
      // 快照缺失/损坏：不静默退化，恢复旧模式与旧子选项。
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      await restoreModeTransition(
        previousMode: previousMode,
        previousRuleDefaultAction: previousSettings.ruleDefaultAction,
        previousDocument: previousDocument ?? currentDocument,
        previousState: previousState,
        previousSystemProxyEnabled: previousSettings.systemProxyEnabled,
        generation: generation)
      return
    }
    guard nextDocument.aclRuntime != currentDocument.aclRuntime else {
      guard settings.systemProxyEnabled else { return }
      state = .starting
      _ = await presentLaunchHealth(nextDocument)
      return
    }

    await deployModeTransition(
      nextDocument,
      previousMode: previousMode,
      previousRuleDefaultAction: previousSettings.ruleDefaultAction,
      previousDocument: previousDocument ?? currentDocument,
      previousState: previousState,
      previousSystemProxyEnabled: previousSettings.systemProxyEnabled,
      generation: generation)
  }

  func runtimeDocument(
    _ document: SslocalRuntimeDocument,
    for mode: ProxyMode
  ) throws -> SslocalRuntimeDocument {
    switch mode {
    case .direct:
      return document.replacingACL(.direct(at: runtimeFileStore.aclFileURL))
    case .global:
      return document.replacingACL(.global(at: runtimeFileStore.aclFileURL))
    case .rule:
      let china = try chinaDirectRules()
      return document.replacingACL(
        .rule(
          at: runtimeFileStore.aclFileURL,
          defaultAction: settings.ruleDefaultAction,
          chinaRules: china))
    case .pac:
      return document.replacingACL(nil)
    }
  }

  /// 内置中国域名直连候选。快照缺失/损坏/版本不匹配时抛错，调用方必须失败
  /// 并保留旧 ACL，不得静默退化成全局（issue #63 AC4）。
  func chinaDirectRules() throws -> [ProxyRule] {
    let snapshot = try BuiltinRuleCatalog.loadGeolocationCN()
    return BuiltinRuleCatalog.chinaDirectRules(from: snapshot)
  }

  private func deployModeTransition(
    _ document: SslocalRuntimeDocument,
    previousMode: ProxyMode,
    previousRuleDefaultAction: RuleDefaultAction,
    previousDocument: SslocalRuntimeDocument,
    previousState: AgentRunState,
    previousSystemProxyEnabled: Bool,
    generation: Int
  ) async {
    guard generation == modeChangeGeneration else { return }
    lastDocument = document
    state = .starting
    guard await execute(.run(document), document: document) else {
      guard generation == modeChangeGeneration else { return }
      await restoreModeTransition(
        previousMode: previousMode,
        previousRuleDefaultAction: previousRuleDefaultAction,
        previousDocument: previousDocument,
        previousState: previousState,
        previousSystemProxyEnabled: previousSystemProxyEnabled,
        generation: generation)
      return
    }

    guard generation == modeChangeGeneration else { return }
    let healthy = await presentLaunchHealth(
      document,
      requiresReceipt: true,
      convergeProxyOnSuccess: false,
      preserveProxyOnFailure: true)
    guard generation == modeChangeGeneration else { return }
    guard healthy else {
      await restoreModeTransition(
        previousMode: previousMode,
        previousRuleDefaultAction: previousRuleDefaultAction,
        previousDocument: previousDocument,
        previousState: previousState,
        previousSystemProxyEnabled: previousSystemProxyEnabled,
        generation: generation)
      return
    }

    lastDocument = document
    await convergeSystemProxy()
  }

  private func restoreModeTransition(
    previousMode: ProxyMode,
    previousRuleDefaultAction: RuleDefaultAction,
    previousDocument: SslocalRuntimeDocument,
    previousState: AgentRunState,
    previousSystemProxyEnabled: Bool,
    generation: Int
  ) async {
    var persistenceFailed = false
    var restoredSettings = settings
    restoredSettings.preferredMode = previousMode.kind
    restoredSettings.ruleDefaultAction = previousRuleDefaultAction
    do {
      try settingsStore.save(restoredSettings)
    } catch {
      persistenceFailed = true
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    }
    guard generation == modeChangeGeneration else { return }
    settings = restoredSettings
    proxyMode = previousMode
    lastDocument = previousDocument

    let expectedDigest = previousDocument.deploymentSHA256
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
      do {
        if currentDocument != previousDocument {
          try runtimeFileStore.write(previousDocument)
        }
      } catch {
        state = .serviceFailed(.runtimeFile)
        await withdrawSystemProxyAfterEntryLoss()
        return
      }

      if !previousInstanceIsRunning {
        switch wrapper {
        case .running(let pid):
          guard sendSignal(pid, SIGUSR1) == 0 else {
            state = .serviceFailed(.agent)
            await withdrawSystemProxyAfterEntryLoss()
            return
          }
        case .notRunning:
          guard await execute(.run(previousDocument), document: previousDocument) else {
            guard generation == modeChangeGeneration else { return }
            await withdrawSystemProxyAfterEntryLoss()
            return
          }
        }
      }
    }

    guard generation == modeChangeGeneration else { return }
    state = .starting
    let restored = await presentLaunchHealth(
      previousDocument,
      requiresReceipt: true,
      convergeProxyOnSuccess: false)
    guard generation == modeChangeGeneration else { return }
    guard restored else {
      await withdrawSystemProxyAfterEntryLoss()
      return
    }

    if settings.systemProxyEnabled != previousSystemProxyEnabled {
      await convergeSystemProxy()
    } else {
      state = previousState
    }
    if persistenceFailed { state = .serviceFailed(.persistence) }
  }
}
