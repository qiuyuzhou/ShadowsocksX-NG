import Foundation

// MARK: - 自定义规则更新结果

/// The result of accepting and saving a rule document, independent of runtime.
enum CustomRuleUpdateOutcome: Equatable, Sendable {
  /// 规则已保存；运行规则模式时应用。
  case saved
  /// 校验拒绝：整批不落地，旧规则保持不变；附可解释原因。
  case rejected([RejectedCustomRule])
  /// 持久化失败：旧规则保持不变。
  case persistenceFailed
  case busy
  case invalidDocument(detail: String)

  var isSuccess: Bool {
    switch self {
    case .saved: true
    default: false
    }
  }
}

/// Final persisted facts, independent of whether runtime application succeeded.
struct RuleDocumentCommit: Sendable {
  let outcome: CustomRuleUpdateOutcome
  let document: CustomRuleDocument?
}

// MARK: - 结果呈现文案

// outcome→文案映射与 outcome 类型同住，供状态行与编辑器两个视图共享。

extension RulesCommitFeedback {
  var summary: String {
    guard outcome.isSuccess else { return outcome.rulesMessage }
    let count: String
    switch operation {
    case .enablement(let enabled):
      count = String.localizedStringWithFormat(
        RulesCopy.text(enabled ? "已启用 %lld 条规则" : "已禁用 %lld 条规则"), Int64(changedCount))
    case .add: count = RulesCopy.text("已新增规则")
    case .edit: count = RulesCopy.text("已编辑规则")
    case .delete:
      count = String.localizedStringWithFormat(
        RulesCopy.text("已删除 %lld 条自定义规则"), Int64(changedCount))
    }
    return count + " · " + RulesCopy.text("已保存")
  }
}

extension CustomRuleUpdateOutcome {
  var rulesMessage: String {
    switch self {
    case .saved: RulesCopy.text("已保存")
    case .persistenceFailed: RulesCopy.text("保存失败，规则未更改")
    case .busy: RulesCopy.text("正在更新规则…")
    case .invalidDocument, .rejected: RulesCopy.text("无法更新规则")
    }
  }

  var failureDetail: String? {
    switch self {
    case .invalidDocument(let detail): detail
    case .rejected(let rejected): rejected.map(\.explanation).joined(separator: "\n")
    default: nil
    }
  }

  var nextStep: String? {
    switch self {
    case .persistenceFailed, .busy: "请重试规则操作。"
    case .invalidDocument, .rejected: "请检查规则数据后再操作。"
    default: nil
    }
  }
}

// MARK: - 自定义规则命令面

extension ProxyRuntimeController {
  /// Validate and atomically save intent; runtime application is a separate worker.
  /// Deployment failure never restores an older saved rule document.
  /// 全局和直连模式不加载自定义规则，但持久化仍然进行（切换到规则模式后生效）。
  func commitRuleDocument(_ document: CustomRuleDocument) async -> RuleDocumentCommit {
    let previous = try? ruleDocuments.load()
    let outcome = await updateRuleDocument(document)
    return RuleDocumentCommit(outcome: outcome, document: ruleDocuments.current ?? previous)
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
    do {
      _ = try ruleDocuments.load()
      try ruleDocuments.save(document)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      return .persistenceFailed
    }
    scheduleRuleApplication()
    return .saved
  }

  /// One worker owns rule deployments. Saves never cancel an in-flight restart;
  /// another saved revision is coalesced and applied after that restart finishes.
  func scheduleRuleApplication() {
    ruleApplicationGeneration += 1
    guard ruleApplicationTask == nil else { return }
    ruleApplicationTask = Task { [weak self] in
      guard let self else { return }
      defer { self.ruleApplicationTask = nil }
      while !Task.isCancelled {
        let generation = self.ruleApplicationGeneration
        do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
        guard generation == self.ruleApplicationGeneration else { continue }
        await self.applySavedRuleDocument()
        if generation == self.ruleApplicationGeneration { return }
      }
    }
  }

  private func applySavedRuleDocument() async {
    guard proxyMode == .rule, settings.agentEnabled, state != .off,
      let currentDocument = lastDocument ?? runtimeFileStore.loadDocument()
    else { return }
    let revision = ruleDocuments.revision
    let plan = RollbackPlan(
      document: currentDocument, state: state,
      payload: .runtimeOnly,
      systemProxyIntentAtCapture: settings.systemProxyEnabled,
      convergeProxyOnIntentChange: false)
    let nextDocument: SslocalRuntimeDocument
    do {
      nextDocument = try await runtimeDocument(currentDocument, for: proxyMode)
    } catch RulePreparationError.superseded {
      return
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      ruleApplicationFailure = .service(.runtimeFile)
      return
    }
    guard nextDocument.aclRuntime != currentDocument.aclRuntime || ruleApplicationFailure != nil
    else {
      ruleApplicationFailure = nil
      return
    }
    modeChangeGeneration += 1
    var ticket = convergenceTicket()
    let result = await apply(
      nextDocument, ticket: &ticket,
      requiresReceipt: true, convergeProxyOnSuccess: false,
      preserveProxyOnFailure: true, proxyTail: .converge, rollback: plan)
    switch result {
    case .applied, .unchanged:
      if revision == ruleDocuments.revision { ruleApplicationFailure = nil }
    case .superseded:
      break
    case .failed:
      let failure = ProxyRuntimeFacts(state: state).failure ?? .service(.runtimeFile)
      _ = await restore(plan, ticket: &ticket)
      if convergenceIsCurrent(ticket), revision == ruleDocuments.revision {
        ruleApplicationFailure = failure
      }
    }
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

  /// 自定义规则安全摘要（issue #66 AC5）：数量 + 内容版本，不含原始域名。
  func readCustomRuleSummary() -> CustomRuleSummary? {
    try? customRuleStore.summary()
  }
}
