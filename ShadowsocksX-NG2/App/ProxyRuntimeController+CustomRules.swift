import Foundation

// MARK: - 自定义规则更新结果

/// 自定义规则更新结果（issue #66）：持久化成功、校验拒绝、持久化失败或部署回滚。
enum CustomRuleUpdateOutcome: Equatable, Sendable {
  /// 规则已保存并生效（或在非规则模式下仅持久化，ACL 不变）。
  case saved
  /// 校验拒绝：整批不落地，旧规则保持不变；附可解释原因。
  case rejected([RejectedCustomRule])
  /// 持久化失败：旧规则保持不变。
  case persistenceFailed
  /// 保存后部署失败并已回滚到旧规则与旧运行时。
  case rolledBack
}

// MARK: - 自定义规则命令面

extension ProxyRuntimeController {
  /// 更新自定义规则（issue #66 AC1）：校验 → 持久化 → 重编译 ACL → 完整重启。
  /// 校验拒绝时整批不落地；部署失败时回滚旧规则、旧 ACL 与旧系统代理状态。
  /// 全局和直连模式不加载自定义规则，但持久化仍然进行（切换到规则模式后生效）。
  func updateCustomRules(_ rules: [CustomRule]) async -> CustomRuleUpdateOutcome {
    let validation = validateCustomRulesForPersistence(rules)
    guard validation.rejected.isEmpty else {
      return .rejected(validation.rejected)
    }

    let previousRules = (try? customRuleStore.load()) ?? []
    let snapshot = ModeTransitionSnapshotForRules(
      document: lastDocument, state: state)

    do {
      try customRuleStore.save(validation.acceptedRules)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.persistence)
      return .persistenceFailed
    }

    return await deployCustomRuleChange(previousRules: previousRules, snapshot: snapshot)
  }

  /// 规则内容变化后重编译 ACL；非规则模式的 ACL 不含自定义规则，无变化即不重启。
  private func deployCustomRuleChange(
    previousRules: [CustomRule],
    snapshot: ModeTransitionSnapshotForRules
  ) async -> CustomRuleUpdateOutcome {
    guard settings.agentEnabled, state != .off,
      let currentDocument = lastDocument ?? runtimeFileStore.loadDocument()
    else {
      return .saved
    }

    let nextDocument: SslocalRuntimeDocument
    do {
      nextDocument = try runtimeDocument(currentDocument, for: proxyMode)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      await restoreCustomRules(previousRules, snapshot: snapshot)
      return .rolledBack
    }
    guard nextDocument.aclRuntime != currentDocument.aclRuntime else {
      return .saved
    }

    modeChangeGeneration += 1
    let generation = modeChangeGeneration
    lastDocument = nextDocument
    state = .starting
    guard await execute(.run(nextDocument), document: nextDocument) else {
      guard generation == modeChangeGeneration else { return .rolledBack }
      await restoreCustomRules(previousRules, snapshot: snapshot)
      return .rolledBack
    }

    guard generation == modeChangeGeneration else { return .rolledBack }
    let healthy = await presentLaunchHealth(
      nextDocument,
      requiresReceipt: true,
      convergeProxyOnSuccess: false,
      preserveProxyOnFailure: true)
    guard generation == modeChangeGeneration else { return .rolledBack }
    guard healthy else {
      await restoreCustomRules(previousRules, snapshot: snapshot)
      return .rolledBack
    }

    lastDocument = nextDocument
    await convergeSystemProxy()
    return .saved
  }

  /// 保存前校验（issue #66 AC2）：固定本地冲突与重复整批拒绝并返回可解释原因。
  /// 单模式遮蔽的规则允许保存（在另一模式可生效），编译时按当前模式过滤并
  /// 通过 `ruleModeValidation` 返回原因；不把无效规则标为生效。
  func validateCustomRulesForPersistence(_ rules: [CustomRule]) -> (
    acceptedRules: [CustomRule], rejected: [RejectedCustomRule]
  ) {
    let base = CustomRuleValidator.validate(
      custom: rules, defaultAction: .proxyWhenUnmatched)
    let hardRejected = base.rejected.filter {
      $0.reason == .conflictsWithFixedLocalScope || $0.reason == .duplicate
    }
    let hardRejectedTokens = Set(hardRejected.map(\.rule.contentToken))
    let accepted = rules.filter { !hardRejectedTokens.contains($0.contentToken) }
    return (accepted, hardRejected)
  }

  private func restoreCustomRules(
    _ previousRules: [CustomRule],
    snapshot: ModeTransitionSnapshotForRules
  ) async {
    do {
      try customRuleStore.save(previousRules)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    }
    guard let previousDocument = snapshot.document else { return }
    lastDocument = previousDocument
    state = .starting
    _ = await execute(.run(previousDocument), document: previousDocument)
    let restored = await presentLaunchHealth(
      previousDocument,
      requiresReceipt: true,
      convergeProxyOnSuccess: false)
    if !restored {
      await withdrawSystemProxyAfterEntryLoss()
    } else {
      state = snapshot.state
    }
  }

  private struct ModeTransitionSnapshotForRules {
    let document: SslocalRuntimeDocument?
    let state: AgentRunState
  }

  /// 自定义规则安全摘要（issue #66 AC5）：数量 + 内容版本，不含原始域名。
  func readCustomRuleSummary() -> CustomRuleSummary? {
    guard let rules = try? customRuleStore.load() else { return nil }
    return CustomRuleSummary.summarizing(rules)
  }
}
