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
      nextDocument = try runtimeDocument(currentDocument, for: mode)
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
      let candidates = try ruleModeCandidateRules()
      return document.replacingACL(
        .rule(
          at: runtimeFileStore.aclFileURL,
          defaultAction: settings.ruleDefaultAction,
          rules: candidates))
    case .pac:
      return document.replacingACL(nil)
    }
  }

  /// 规则模式候选按默认动作取对应来源（issue #65/#66）：「未匹配时代理」用
  /// 中国直连候选；「未匹配时直连」用 GFWList 代理候选。两种默认动作不把
  /// 全部内置来源无条件并集。自定义规则与对应内置来源合并（issue #66）；
  /// 被遮蔽的自定义规则不进入 ACL，并经 `ruleModeValidation` 返回原因。
  /// 全局和直连模式不加载自定义规则（它们不调用本方法）。
  func ruleModeCandidateRules() throws -> [ProxyRule] {
    try ruleModeValidation().accepted
  }

  /// 规则模式编译校验结果：可生效候选 + 被拒绝的自定义规则及原因（issue #66 AC2）。
  func ruleModeValidation() throws -> CustomRuleValidationResult {
    let custom = try customRuleStore.load()
    switch settings.ruleDefaultAction {
    case .proxyWhenUnmatched:
      let builtIn = try chinaDirectRules()
      let validated = CustomRuleValidator.validate(
        custom: custom, builtIn: builtIn, defaultAction: .proxyWhenUnmatched)
      return CustomRuleValidationResult(
        accepted: builtIn + validated.accepted, rejected: validated.rejected)
    case .directWhenUnmatched:
      let builtIn = try gfwlistRules()
      let validated = CustomRuleValidator.validate(
        custom: custom, builtIn: builtIn, defaultAction: .directWhenUnmatched)
      return CustomRuleValidationResult(
        accepted: builtIn + validated.accepted, rejected: validated.rejected)
    }
  }

  /// 内置中国直连候选：geolocation-cn 域名 + china-operator-ip IPv4 CIDR
  /// （issue #63/#64）。快照缺失/损坏/版本不匹配时抛错，调用方必须失败
  /// 并保留旧 ACL，不得静默退化成全局（issue #63 AC4）。
  func chinaDirectRules() throws -> [ProxyRule] {
    let geolocation = try BuiltinRuleCatalog.loadGeolocationCN()
    let chinaIPv4 = try BuiltinRuleCatalog.loadChinaIPv4()
    return BuiltinRuleCatalog.chinaDirectRules(from: [geolocation, chinaIPv4])
  }

  /// GFWList 候选（issue #65）：可准确表达且未被更宽代理规则遮蔽的规则
  /// （含未遮蔽例外），参与 `bypass_all` ACL 编译。
  func gfwlistRules() throws -> [ProxyRule] {
    BuiltinRuleCatalog.gfwlistRules(from: try BuiltinRuleCatalog.loadGFWList())
  }

  private func deployModeTransition(
    _ document: SslocalRuntimeDocument,
    snapshot: ModeTransitionSnapshot,
    generation: Int
  ) async {
    guard generation == modeChangeGeneration else { return }
    lastDocument = document
    state = .starting
    guard await execute(.run(document), document: document) else {
      guard generation == modeChangeGeneration else { return }
      await restoreModeTransition(snapshot: snapshot, generation: generation)
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
      await restoreModeTransition(snapshot: snapshot, generation: generation)
      return
    }

    lastDocument = document
    await convergeSystemProxy()
  }

  private func restoreModeTransition(
    snapshot: ModeTransitionSnapshot,
    generation: Int
  ) async {
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
    guard generation == modeChangeGeneration else { return }
    settings = restoredSettings
    proxyMode = snapshot.mode
    lastDocument = previousDocument

    guard await restoreRuntimeDocument(previousDocument, generation: generation)
    else { return }

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

    if settings.systemProxyEnabled != snapshot.settings.systemProxyEnabled {
      await convergeSystemProxy()
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
    generation: Int
  ) async -> Bool {
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
      if currentDocument != previousDocument {
        do {
          try runtimeFileStore.write(previousDocument)
        } catch {
          state = .serviceFailed(.runtimeFile)
          await withdrawSystemProxyAfterEntryLoss()
          return false
        }
      }
      if !previousInstanceIsRunning {
        guard
          await relaunchPreviousInstance(
            wrapper: wrapper, previousDocument: previousDocument, generation: generation)
        else { return false }
      }
    }
    return true
  }

  /// 旧实例未在运行时按需拉起：在跑的 wrapper 用 SIGUSR1 唤醒重读，否则重新执行。
  private func relaunchPreviousInstance(
    wrapper: WrapperProcessState,
    previousDocument: SslocalRuntimeDocument,
    generation: Int
  ) async -> Bool {
    switch wrapper {
    case .running(let pid):
      guard sendSignal(pid, SIGUSR1) == 0 else {
        state = .serviceFailed(.agent)
        await withdrawSystemProxyAfterEntryLoss()
        return false
      }
    case .notRunning:
      guard await execute(.run(previousDocument), document: previousDocument) else {
        guard generation == modeChangeGeneration else { return false }
        await withdrawSystemProxyAfterEntryLoss()
        return false
      }
    }
    return true
  }
}
