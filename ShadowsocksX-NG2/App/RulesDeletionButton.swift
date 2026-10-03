import SwiftUI

/// A single confirmation captures custom UUIDs before starting the shared transaction.
/// Gate rejections and commit failures surface through the workflow's commit
/// feedback, not a local alert.
struct RulesDeletionButton: View {
  @ObservedObject var workflow: RulesWorkflow
  @State private var confirmation: CustomRuleDeletion?

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
        Task { await workflow.deleteCustomRules(captured) }
      }
      Button(RulesCopy.text("取消"), role: .cancel) { confirmation = nil }
    } message: { _ in
      Text(RulesCopy.text("只删除所选自定义条目。其他来源的规则和已有禁用记录将保留。"))
    }
  }

  private func countText(_ key: String, _ count: Int) -> String {
    String.localizedStringWithFormat(RulesCopy.text(key), Int64(count))
  }
}
