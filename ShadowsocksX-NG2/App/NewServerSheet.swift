import SwiftUI

/// 「新建服务器」表单（服务器视图工具栏入口）：字段、校验与插件区镜像编辑
/// 表单，默认值端口 8388、加密 aes-256-gcm、插件「无」。落点由父视图按既有
/// `importTargetParent` 语义在打开时固定；提交成功关闭表单并把新身份交给
/// selection（由父视图选中）；校验/提交失败留在表单，错误经共享呈现器点名。
struct NewServerSheet: View {
  let workflow: CatalogWorkflow
  let errors: ErrorAlertPresenter
  let parent: NodeID?
  @Binding var selection: NodeID?
  @Environment(\.dismiss) private var dismiss

  @State private var address = ""
  @State private var port = 8388
  @State private var encryptionMethod = "aes-256-gcm"
  @State private var password = ""
  @State private var remark = ""
  @State private var pluginChoice: PluginSelection = .none
  @State private var pluginOptionsText = ""
  @State private var showPassword = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      VStack(alignment: .leading, spacing: 4) {
        Text("新建服务器")
          .font(.title2)
        Text("保存后加入目录；密码存入钥匙串，目录只持引用。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 18) {
        GridRow {
          column("服务器地址") {
            TextField("服务器地址", text: $address)
              .textFieldStyle(.roundedBorder)
          }
          column("端口") {
            TextField("端口", value: $port, format: .number.grouping(.never))
              .textFieldStyle(.roundedBorder)
          }
        }
        GridRow {
          column("加密方式") {
            Picker("加密方式", selection: $encryptionMethod) {
              ForEach(EncryptionMethodCatalog.supported.sorted(), id: \.self) {
                Text($0).tag($0)
              }
            }
          }
          column("备注") {
            TextField("备注", text: $remark)
              .textFieldStyle(.roundedBorder)
          }
        }
        GridRow {
          column("密码") {
            HStack(spacing: 8) {
              Group {
                if showPassword {
                  TextField("密码", text: $password)
                } else {
                  SecureField("密码", text: $password)
                }
              }
              .textFieldStyle(.roundedBorder)
              Button {
                showPassword.toggle()
              } label: {
                Image(systemName: showPassword ? "eye.slash" : "eye")
              }
              .buttonStyle(.borderless)
              .help(showPassword ? "隐藏密码" : "显示密码")
            }
          }
          .gridCellColumns(2)
        }
        GridRow {
          column("受管理插件与参数") {
            ServerPluginSection(
              selection: $pluginChoice,
              optionsText: $pluginOptionsText,
              plugin: pluginSection,
              isEditable: true)
          }
          .gridCellColumns(2)
        }
      }

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
      selection: pluginChoice,
      managed: ManagedPluginCatalog.plugins,
      provided: true,
      optionsPresent: false,
      options: "")
  }

  private func create() {
    Task {
      do {
        let id = try await workflow.createServer(
          ServerEditDraft(
            address: address,
            port: port,
            encryptionMethod: encryptionMethod,
            password: password,
            remark: remark,
            plugin: pluginChoice,
            pluginOptions: pluginOptionsText),
          into: parent)
        selection = id
        dismiss()
      } catch {
        errors.present(error)
      }
    }
  }

  private func column<Content: View>(
    _ label: String, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(label)
        .font(.callout.weight(.medium))
        .foregroundStyle(.secondary)
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
