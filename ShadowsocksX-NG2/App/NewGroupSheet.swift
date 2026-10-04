import SwiftUI

/// 失败保留名称和打开时固定的父组；创建成功才关闭表单。
struct NewGroupSheet: View {
  let workflow: CatalogWorkflow
  let errors: ErrorAlertPresenter
  let parent: NodeID?
  let onCreated: (NodeID) -> Void
  @Environment(\.dismiss) private var dismiss
  @State private var name = ""
  @State private var isSubmitting = false
  @FocusState private var nameFocused: Bool

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("新建分组").font(.title2)
      TextField("名称", text: $name)
        .focused($nameFocused)
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("创建") { create() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 360)
    .disabled(isSubmitting)
    .interactiveDismissDisabled(isSubmitting)
    .defaultFocus($nameFocused, true)
  }

  private func create() {
    guard !isSubmitting else { return }
    isSubmitting = true
    Task {
      defer { isSubmitting = false }
      do {
        let id = try await workflow.createGroup(named: name, into: parent)
        onCreated(id)
        dismiss()
      } catch {
        errors.present(error)
      }
    }
  }
}
