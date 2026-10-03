import SwiftUI

/// A reserved toolbar row keeps feedback from resizing or replacing the rule table.
struct RulesOperationStatusView: View {
  @ObservedObject var workflow: RulesWorkflow
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
