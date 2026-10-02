import SwiftUI

/// A reserved toolbar row keeps feedback from resizing or replacing the rule table.
struct RulesOperationStatusView: View {
  @ObservedObject var workflow: RulesWorkflow
  var onShowRuntime: () -> Void
  @State private var showsDetails = false

  var body: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      switch workflow.snapshot.operationStatus {
      case .idle, .initialLoading:
        EmptyView()
      case .updating:
        progress("正在更新规则…")
      case .refreshing:
        progress("正在加载规则…")
      case .collectionIncomplete:
        Label(RulesCopy.text("集合不完整"), systemImage: "exclamationmark.triangle")
          .foregroundStyle(.orange)
        detailsButton
        refreshButton
      case .feedback(let feedback):
        Label {
          Text(verbatim: feedback.summary).lineLimit(1).truncationMode(.middle)
        } icon: {
          Image(
            systemName: feedback.outcome.isSuccess ? "checkmark.circle" : "exclamationmark.triangle"
          )
          .foregroundStyle(feedback.outcome.isSuccess ? Color.secondary : Color.orange)
        }
        .help(feedback.summary)
        if !feedback.outcome.isSuccess {
          detailsButton
          if feedback.outcome.needsRuntimeInspection {
            Button(RulesCopy.text("查看运行状态"), action: onShowRuntime)
          }
          Button(RulesCopy.text("关闭"), systemImage: "xmark") {
            workflow.dismissFeedback()
          }.labelStyle(.iconOnly)
        }
      }
    }
    .font(.caption)
    .controlSize(.small)
    .frame(maxWidth: .infinity, minHeight: 22, maxHeight: 22)
    .onChange(of: workflow.snapshot.operationStatus) { _, _ in showsDetails = false }
  }

  private func progress(_ key: String) -> some View {
    HStack(spacing: 6) {
      ProgressView().controlSize(.mini)
      Text(RulesCopy.text(key))
    }.accessibilityElement(children: .combine)
  }

  private var detailsButton: some View {
    Button(RulesCopy.text("查看详情")) { showsDetails = true }
      .popover(isPresented: $showsDetails) { details }
  }

  private var refreshButton: some View {
    Button(RulesCopy.text("刷新规则")) {
      showsDetails = false
      Task { await workflow.refresh(retryFailedSources: true) }
    }
  }

  private var details: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 10) {
        if let feedback = workflow.snapshot.commitFeedback {
          Text(verbatim: feedback.summary).font(.headline)
          if let detail = feedback.outcome.failureDetail {
            Text(verbatim: detail).textSelection(.enabled)
          }
          if let nextStep = feedback.outcome.nextStep {
            Text(RulesCopy.text(nextStep))
          }
        }
        if !workflow.snapshot.issues.isEmpty {
          Text(RulesCopy.text("规则列表未更新，请刷新规则。"))
          RulesCollectionIssuesView(issues: workflow.snapshot.issues)
        }
      }.frame(maxWidth: .infinity, alignment: .leading).padding()
    }.frame(width: 380).frame(maxHeight: 300)
  }
}

struct RulesCollectionIssuesView: View {
  let issues: [RulesPageSnapshot.Issue]

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(RulesCopy.text("集合不完整时，覆盖解释仅基于已加载来源。"))
      ForEach(issues, id: \.self) { issue in
        Text(verbatim: description(issue)).textSelection(.enabled)
      }
    }.font(.caption)
  }

  private func description(_ issue: RulesPageSnapshot.Issue) -> String {
    switch issue {
    case .userDocument(let detail): "\(RulesCopy.text("自定义规则")): \(detail)"
    case .builtin(let source, let detail): "\(source.label): \(detail)"
    }
  }
}

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
    }
    let application: String
    switch outcome {
    case .applied: application = "已应用"
    case .runtimeUnchanged: application = "无需重新应用"
    default: application = "运行规则模式时应用"
    }
    return count + " · " + RulesCopy.text(application)
  }
}

extension CustomRuleUpdateOutcome {
  var rulesMessage: String {
    switch self {
    case .saved: RulesCopy.text("已保存")
    case .applied: RulesCopy.text("已应用")
    case .runtimeUnchanged: RulesCopy.text("无需重新应用")
    case .persistenceFailed: RulesCopy.text("保存失败，规则未更改")
    case .rolledBack: RulesCopy.text("应用失败，已恢复原规则")
    case .recoveryFailed: RulesCopy.text("恢复失败，请检查运行状态")
    case .runtimeChanged: RulesCopy.text("运行状态已变化，请检查当前状态")
    case .busy: RulesCopy.text("正在更新规则…")
    case .invalidDocument, .rejected: RulesCopy.text("无法更新规则")
    }
  }

  var needsRuntimeInspection: Bool {
    switch self {
    case .recoveryFailed, .runtimeChanged: true
    default: false
    }
  }

  var failureDetail: String? {
    switch self {
    case .recoveryFailed(let detail, let rulesRestored):
      RulesCopy.text(rulesRestored ? "已恢复原规则" : "已保存") + "\n" + detail
    case .runtimeChanged(let rulesRestored):
      RulesCopy.text(rulesRestored ? "已恢复原规则" : "已保存")
    case .invalidDocument(let detail): detail
    case .rejected(let rejected): rejected.map(\.explanation).joined(separator: "\n")
    default: nil
    }
  }

  var nextStep: String? {
    switch self {
    case .persistenceFailed, .rolledBack, .busy: "请重试规则操作。"
    case .recoveryFailed, .runtimeChanged: "请在首页检查当前代理运行状态。"
    case .invalidDocument, .rejected: "请检查规则数据后再操作。"
    default: nil
    }
  }
}
