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

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("新建服务器")
          .font(.title2)
        Text("保存后加入目录；密码存入钥匙串，目录只持引用。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      ServerFormFieldsGrid(fields: fields, plugin: pluginSection, isEditable: true)

      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("创建") { create() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 520, minHeight: 400)
  }

  /// 插件区状态：无既有引用，参数按未配置呈现。新表单只能产生「无」或受管
  /// 选择；`provided` 恒为真——新建尚无引用可点名，可执行文件缺失由激活
  /// 语义拒绝并在编辑面呈现。
  private var pluginSection: PluginSectionState {
    PluginSectionState(
      selection: fields.pluginChoice,
      managed: ManagedPluginCatalog.plugins,
      provided: true,
      optionsPresent: false,
      options: "")
  }

  private func create() {
    Task {
      do {
        let id = try await workflow.createServer(fields.draft, into: parent)
        selection = id
        dismiss()
      } catch {
        errors.present(error)
      }
    }
  }
}
