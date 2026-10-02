import Foundation

// MARK: - 自定义规则更新结果

/// 自定义规则更新结果（issue #66）：持久化成功、校验拒绝、持久化失败或部署回滚。
enum CustomRuleUpdateOutcome: Equatable, Sendable {
  /// 规则已保存；运行规则模式时应用。
  case saved
  case applied
  case runtimeUnchanged
  /// 校验拒绝：整批不落地，旧规则保持不变；附可解释原因。
  case rejected([RejectedCustomRule])
  /// 持久化失败：旧规则保持不变。
  case persistenceFailed
  /// 保存后部署失败并已回滚到旧规则与旧运行时。
  case rolledBack
  case recoveryFailed(detail: String, rulesRestored: Bool)
  case runtimeChanged(rulesRestored: Bool)
  case busy
  case invalidDocument(detail: String)

  var isSuccess: Bool {
    switch self {
    case .saved, .applied, .runtimeUnchanged: true
    default: false
    }
  }
}

/// Final persisted facts, independent of whether runtime application succeeded.
struct RuleDocumentCommit: Sendable {
  let outcome: CustomRuleUpdateOutcome
  let document: CustomRuleDocument?
}

// MARK: - 自定义规则命令面

extension ProxyRuntimeController {
  /// 更新自定义规则（issue #66 AC1）：校验 → 持久化 → 重编译 ACL → 完整重启。
  /// 校验拒绝时整批不落地；部署失败时回滚旧规则、旧 ACL 与旧系统代理状态。
  /// 全局和直连模式不加载自定义规则，但持久化仍然进行（切换到规则模式后生效）。
  func commitRuleDocument(_ document: CustomRuleDocument) async -> RuleDocumentCommit {
    let previous = try? ruleDocuments.load()
    let outcome = await updateRuleDocument(document)
    return RuleDocumentCommit(outcome: outcome, document: ruleDocuments.current ?? previous)
  }

  func updateCustomRules(_ rules: [CustomRule]) async -> CustomRuleUpdateOutcome {
    do {
      let previous = try ruleDocuments.load()
      return await updateRuleDocument(
        CustomRuleDocument(rules: rules, disabledIdentities: previous.disabledIdentities))
    } catch { return .persistenceFailed }
  }

  func updateRuleDocument(_ document: CustomRuleDocument) async -> CustomRuleUpdateOutcome {
    guard !isUpdatingRules else { return .busy }
    isUpdatingRules = true
    defer { isUpdatingRules = false }
    let validation = validateCustomRulesForPersistence(document.rules)
    guard validation.rejected.isEmpty else { return .rejected(validation.rejected) }
    guard
      document.disabledIdentities.isDisjoint(
        with:
          Set(RuleCoverage.fixedLocalMatches.map { RuleIdentity(action: .direct, match: $0) }))
    else { return .invalidDocument(detail: "Fixed local policy cannot be disabled") }
    let previous: CustomRuleDocument
    let snapshot = ModeTransitionSnapshotForRules(
      document: lastDocument ?? runtimeFileStore.loadDocument(), state: state)
    do {
      previous = try ruleDocuments.load()
      try ruleDocuments.save(document)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      return .persistenceFailed
    }
    return await deployCustomRuleChange(previousRules: previous, snapshot: snapshot)
  }

  /// 规则内容变化后重编译 ACL；非规则模式的 ACL 不含自定义规则，无变化即不重启。
  private func deployCustomRuleChange(
    previousRules: CustomRuleDocument,
    snapshot: ModeTransitionSnapshotForRules
  ) async -> CustomRuleUpdateOutcome {
    guard proxyMode == .rule, settings.agentEnabled, state != .off,
      let currentDocument = lastDocument ?? runtimeFileStore.loadDocument()
    else {
      return .saved
    }

    let nextDocument: SslocalRuntimeDocument
    do {
      nextDocument = try await runtimeDocument(currentDocument, for: proxyMode)
    } catch RulePreparationError.superseded {
      return .runtimeChanged(rulesRestored: false)
    } catch {
      return restoreRulesAfterPreparationFailure(previousRules, error: error)
    }
    guard nextDocument.aclRuntime != currentDocument.aclRuntime else {
      return .runtimeUnchanged
    }

    let preparation = runtimePreparationGeneration
    modeChangeGeneration += 1
    let generation = modeChangeGeneration
    let runtimeGeneration = flowGeneration + 1
    let contract = try? PreparedRuntimeContract(nextDocument)
    lastDocument = nextDocument
    state = .starting
    guard await execute(.run(nextDocument), document: nextDocument, preparedContract: contract)
    else {
      guard ruleDeploymentIsCurrent(preparation, generation, runtimeGeneration)
      else {
        return .runtimeChanged(rulesRestored: false)
      }
      return await restoreCustomRules(previousRules, snapshot: snapshot)
    }

    guard ruleDeploymentIsCurrent(preparation, generation, runtimeGeneration)
    else {
      return .runtimeChanged(rulesRestored: false)
    }
    let healthy = await presentLaunchHealth(
      nextDocument,
      requiresReceipt: true,
      convergeProxyOnSuccess: false,
      preserveProxyOnFailure: true, preparedContract: contract)
    guard ruleDeploymentIsCurrent(preparation, generation, runtimeGeneration)
    else {
      return .runtimeChanged(rulesRestored: false)
    }
    guard healthy else {
      return await restoreCustomRules(previousRules, snapshot: snapshot)
    }

    lastDocument = nextDocument
    await convergeSystemProxy()
    guard ruleDeploymentIsCurrent(preparation, generation, runtimeGeneration)
    else {
      return .runtimeChanged(rulesRestored: false)
    }
    return .applied
  }

  private func restoreRulesAfterPreparationFailure(
    _ previousRules: CustomRuleDocument, error: Error
  ) -> CustomRuleUpdateOutcome {
    RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    do {
      try ruleDocuments.save(previousRules)
      return .rolledBack
    } catch {
      return .recoveryFailed(detail: String(describing: error), rulesRestored: false)
    }
  }

  private func ruleDeploymentIsCurrent(
    _ preparation: Int, _ mode: Int, _ runtime: Int
  ) -> Bool {
    preparation == runtimePreparationGeneration && mode == modeChangeGeneration
      && runtime == flowGeneration && settings.agentEnabled
  }

  /// 保存前校验（issue #66 AC2）：固定本地冲突与重复整批拒绝并返回可解释原因。
  /// 同行动覆盖和相反行动遮蔽不阻止保存；编译时按当前骨架解释完整集合。
  func validateCustomRulesForPersistence(_ rules: [CustomRule]) -> (
    acceptedRules: [CustomRule], rejected: [RejectedCustomRule]
  ) {
    let base = CustomRuleValidator.hardValidation(custom: rules)
    let hardRejected = base.rejected.filter {
      $0.reason == .conflictsWithFixedLocalScope || $0.reason == .duplicate
    }
    let hardRejectedTokens = Set(hardRejected.map(\.rule.contentToken))
    let accepted = rules.filter { !hardRejectedTokens.contains($0.contentToken) }
    return (accepted, hardRejected)
  }

  private func restoreCustomRules(
    _ previousRules: CustomRuleDocument,
    snapshot: ModeTransitionSnapshotForRules
  ) async -> CustomRuleUpdateOutcome {
    var failures: [String] = []
    do {
      try ruleDocuments.save(previousRules)
    } catch {
      failures.append(String(describing: error))
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    }
    let rulesRestored = failures.isEmpty
    guard let previousDocument = snapshot.document else {
      return failures.isEmpty
        ? .rolledBack
        : .recoveryFailed(detail: failures.joined(separator: "; "), rulesRestored: rulesRestored)
    }
    guard settings.agentEnabled else {
      return .runtimeChanged(rulesRestored: rulesRestored)
    }
    let modeGeneration = modeChangeGeneration
    let preparation = runtimePreparationGeneration
    let runtimeGeneration = flowGeneration + 1
    let contract = try? PreparedRuntimeContract(previousDocument)
    lastDocument = previousDocument
    state = .starting
    let executed = await execute(
      .run(previousDocument), document: previousDocument, preparedContract: contract)
    guard ruleDeploymentIsCurrent(preparation, modeGeneration, runtimeGeneration)
    else {
      return .runtimeChanged(rulesRestored: rulesRestored)
    }
    guard executed else {
      failures.append(String(describing: state))
      await holdSystemProxyIntent()
      return .recoveryFailed(detail: failures.joined(separator: "; "), rulesRestored: rulesRestored)
    }
    let healthy = await presentLaunchHealth(
      previousDocument, requiresReceipt: true, convergeProxyOnSuccess: false,
      preparedContract: contract)
    guard ruleDeploymentIsCurrent(preparation, modeGeneration, runtimeGeneration)
    else {
      return .runtimeChanged(rulesRestored: rulesRestored)
    }
    if !healthy {
      failures.append(String(describing: state))
      await holdSystemProxyIntent()
    } else {
      state = snapshot.state
    }
    return failures.isEmpty
      ? .rolledBack
      : .recoveryFailed(detail: failures.joined(separator: "; "), rulesRestored: rulesRestored)
  }

  private struct ModeTransitionSnapshotForRules {
    let document: SslocalRuntimeDocument?
    let state: AgentRunState
  }

  /// 自定义规则安全摘要（issue #66 AC5）：数量 + 内容版本，不含原始域名。
  func readCustomRuleSummary() -> CustomRuleSummary? {
    try? customRuleStore.summary()
  }
}
