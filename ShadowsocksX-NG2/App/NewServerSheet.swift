import SwiftUI

/// 「新建服务器」表单（服务器视图工具栏入口）：连接字段草稿与表单栅格走
/// 共享 `ServerFormFields`（与编辑表单同一 interface），默认值端口 8388、
/// 加密 aes-256-gcm、插件「无」。落点由父视图按既有
/// `importTargetParent` 语义在打开时固定；提交成功关闭表单并把新身份交给
/// selection（由父视图选中）；校验/提交失败留在表单，错误经共享呈现器点名。
struct NewServerSheet: View {
  let workflow: CatalogWorkflow
  let errors: ErrorAlertPresenter
  let parent: NodeID?
  @Binding var selection: NodeID?
  @Environment(\.dismiss) private var dismiss

  /// 连接字段草稿由共享 module 持有（与编辑表单同一 interface），默认值
  /// 端口 8388、加密 aes-256-gcm、插件「无」。
  @StateObject private var fields = ServerFormFields.newForm()
  @State private var isSubmitting = false
  @FocusState private var fieldFocus: ServerFormField?

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("新建服务器")
        .font(.title2)

      ServerFormFieldsGrid(
        fields: fields, plugin: pluginSection, isEditable: !isSubmitting,
        fieldFocus: $fieldFocus)

      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("创建") { create() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .disabled(isSubmitting)
    .interactiveDismissDisabled(isSubmitting)
    .defaultFocus($fieldFocus, .name)
    .padding(20)
    .frame(minWidth: 520, minHeight: 400)
  }

  /// 插件区状态经 workflow 投影（与编辑面同缝），选中态跟随草稿。
  private var pluginSection: PluginSectionState {
    workflow.newFormPluginSection(selection: fields.pluginChoice)
  }

  private func create() {
    guard !isSubmitting else { return }
    guard fields.validateForSubmit(), let draft = fields.draft else {
      fieldFocus = fields.firstErrorField
      return
    }
    isSubmitting = true
    Task {
      defer { isSubmitting = false }
      do {
        let id = try await workflow.createServer(draft, into: parent)
        selection = id
        dismiss()
      } catch {
        errors.present(error)
      }
    }
  }
}
