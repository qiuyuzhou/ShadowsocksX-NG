import SwiftUI

/// 服务器表单草稿（UI 持有）：连接字段草稿状态与「字段 ↔ ServerEditForm/
/// ServerEditDraft 命令」的映射只在此写一次；新建与编辑两个表单面各自
/// `@StateObject` 持有一份，经 `load(from:)` 装载、`draft` 提交，第三个表单
/// 面接入只需学这一对方法。栅格渲染见 `ServerFormFieldsGrid`；订阅只读禁用
/// 与插件区 facts 由 caller 注入。
@MainActor
final class ServerFormFields: ObservableObject {
  @Published var address = ""
  @Published var port = 8388
  @Published var encryptionMethod = ""
  @Published var password = ""
  @Published var remark = ""
  @Published var pluginChoice: PluginSelection = .none
  @Published var pluginOptionsText = ""
  @Published var showPassword = false

  /// 新建表单的默认字段：端口 8388、加密 aes-256-gcm、插件「无」。
  static func newForm() -> ServerFormFields {
    let fields = ServerFormFields()
    fields.encryptionMethod = "aes-256-gcm"
    return fields
  }

  /// 当前 sslocal 能力目录；目录中既有的未知方法原样追加显示，便于用户修复。
  /// 新建面初值恒在集内，追加分支不会触发，与仅列集内值行为一致。
  var methodChoices: [String] {
    var choices = EncryptionMethodCatalog.supported.sorted()
    if !encryptionMethod.isEmpty && !choices.contains(encryptionMethod) {
      choices.append(encryptionMethod)
    }
    return choices
  }

  /// 从编辑面状态装载（凭据明文只在编辑命令中出现，story 10/11）；重置密码
  /// 明文显示。
  func load(from state: ServerEditForm) {
    address = state.address
    port = state.port
    encryptionMethod = state.encryptionMethod
    password = state.password
    remark = state.remark
    pluginChoice = state.plugin.selection
    pluginOptionsText = state.plugin.options
    showPassword = false
  }

  /// 提交载荷：配置与凭据字段作为一个逻辑变更（story 12）。
  var draft: ServerEditDraft {
    ServerEditDraft(
      address: address,
      port: port,
      encryptionMethod: encryptionMethod,
      password: password,
      remark: remark,
      plugin: pluginChoice,
      pluginOptions: pluginOptionsText)
  }
}

/// 共享表单栅格：地址/端口、加密/备注、密码全宽（reveal）、插件区全宽。
/// `isEditable` 为假时整表禁用（订阅节点远端管理）；插件区 facts 由 caller
/// 注入——新建面无既有引用，编辑面用编辑命令解析出的状态。
struct ServerFormFieldsGrid: View {
  @ObservedObject var fields: ServerFormFields
  let plugin: PluginSectionState?
  let isEditable: Bool

  var body: some View {
    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 18) {
      GridRow {
        column("服务器地址") {
          TextField("服务器地址", text: $fields.address)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
        }
        column("端口") {
          TextField("端口", value: $fields.port, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
        }
      }
      GridRow {
        column("加密方式") {
          Picker("加密方式", selection: $fields.encryptionMethod) {
            ForEach(fields.methodChoices, id: \.self) { Text($0).tag($0) }
          }
          .disabled(!isEditable)
        }
        column("备注") {
          TextField("备注", text: $fields.remark)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
        }
      }
      GridRow {
        column("密码") {
          HStack(spacing: 8) {
            Group {
              if fields.showPassword {
                TextField("密码", text: $fields.password)
              } else {
                SecureField("密码", text: $fields.password)
              }
            }
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
            Button {
              fields.showPassword.toggle()
            } label: {
              Image(systemName: fields.showPassword ? "eye.slash" : "eye")
            }
            .buttonStyle(.borderless)
            .help(fields.showPassword ? "隐藏密码" : "显示密码")
          }
        }
        .gridCellColumns(2)
      }
      GridRow {
        column("受管理插件与参数") {
          ServerPluginSection(
            selection: $fields.pluginChoice,
            optionsText: $fields.pluginOptionsText,
            plugin: plugin,
            isEditable: isEditable)
        }
        .gridCellColumns(2)
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
