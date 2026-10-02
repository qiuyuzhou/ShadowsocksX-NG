import SwiftUI

/// A single confirmation captures custom UUIDs before starting the shared transaction.
struct RulesDeletionButton: View {
  @ObservedObject var workflow: RulesWorkflow
  @State private var confirmation: CustomRuleDeletion?
  @State private var failure: CustomRuleDeletionResult.Failure?

  var body: some View {
    Button {
      confirmation = workflow.prepareCustomRuleDeletion()
    } label: {
      Text(verbatim: countText("删除 %lld 条自定义规则…", workflow.deletableSelection.count))
    }
    .disabled(
      workflow.deletableSelection.isEmpty || !workflow.snapshot.isComplete
        || workflow.snapshot.isCommitting
    )
    .alert(
      countText("删除 %lld 条自定义规则？", confirmation?.customIDs.count ?? 0),
      isPresented: Binding(
        get: { confirmation != nil }, set: { if !$0 { confirmation = nil } }),
      presenting: confirmation
    ) { captured in
      Button(RulesCopy.text("删除"), role: .destructive) {
        confirmation = nil
        Task {
          if case .unavailable(let reason) = await workflow.deleteCustomRules(captured) {
            failure = reason
          }
        }
      }
      Button(RulesCopy.text("取消"), role: .cancel) { confirmation = nil }
    } message: { _ in
      Text(RulesCopy.text("只删除所选自定义条目。其他来源的规则和已有禁用记录将保留。"))
    }
    .alert(
      RulesCopy.text("无法更新规则"),
      isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })
    ) {
      Button(RulesCopy.text("关闭")) { failure = nil }
    } message: {
      Text(RulesCopy.text(failureMessage))
    }
  }

  private func countText(_ key: String, _ count: Int) -> String {
    String.localizedStringWithFormat(RulesCopy.text(key), Int64(count))
  }

  private var failureMessage: String {
    switch failure {
    case .staleConfirmation: "规则集合已变化，请重新确认删除。"
    case .incompleteCollection: "集合不完整"
    case .busy, nil: "正在更新规则…"
    }
  }
}
