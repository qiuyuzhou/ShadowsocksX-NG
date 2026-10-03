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
  @Published var remark = "" {
    didSet {
      if !nameIsEmpty { hasNameError = false }
    }
  }
  @Published var pluginChoice: PluginSelection = .none
  @Published var pluginOptionsText = ""
  @Published var showPassword = false
  @Published private(set) var hasNameError = false
  @Published private var savedDraft: ServerEditDraft?

  var hasChanges: Bool {
    guard let savedDraft else { return false }
    return draft != savedDraft
  }

  private var nameIsEmpty: Bool {
    remark.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
  }

  /// 提交时才提示名称错误；后台仍独立执行完整校验。
  func validateName() -> Bool {
    hasNameError = nameIsEmpty
    return !hasNameError
  }

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
    hasNameError = false
    savedDraft = draft
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

/// 新建与编辑共享的名称优先表单；焦点由提交入口持有，校验失败时定位名称。
struct ServerFormFieldsGrid: View {
  @ObservedObject var fields: ServerFormFields
  let plugin: PluginSectionState?
  let isEditable: Bool
  let nameFocus: FocusState<Bool>.Binding

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      column("名称") {
        TextField("名称", text: $fields.remark, prompt: Text("例如：香港服务器"))
          .textFieldStyle(.roundedBorder)
          .focused(nameFocus)
          .disabled(!isEditable)
        if fields.hasNameError {
          Text("请输入服务器名称")
            .font(.footnote)
            .foregroundStyle(.red)
        }
      }
      ServerEndpointLayout {
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
      column("加密方式") {
        Picker("加密方式", selection: $fields.encryptionMethod) {
          ForEach(fields.methodChoices, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden()
        .accessibilityLabel("加密方式")
        .disabled(!isEditable)
      }
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
          .textContentType(nil)
          .autocorrectionDisabled()
          .disabled(!isEditable)
          Button {
            fields.showPassword.toggle()
          } label: {
            Image(systemName: fields.showPassword ? "eye.slash" : "eye")
          }
          .buttonStyle(.borderless)
          .help(fields.showPassword ? "隐藏密码" : "显示密码")
          .accessibilityLabel(fields.showPassword ? "隐藏密码" : "显示密码")
        }
      }
      column("插件") {
        ServerPluginSection(
          selection: $fields.pluginChoice,
          optionsText: $fields.pluginOptionsText,
          plugin: plugin,
          isEditable: isEditable)
      }
    }
  }

  private func column<Content: View>(
    _ label: LocalizedStringKey, @ViewBuilder content: () -> Content
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

/// 扣除间距后按 4:1 分配地址和端口宽度，高度由字段自身决定。
private struct ServerEndpointLayout: Layout {
  private let spacing: CGFloat = 20

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let width = proposal.width ?? 480
    let unit = max(0, width - spacing) / 5
    let height =
      subviews.enumerated().map { index, view in
        view.sizeThatFits(ProposedViewSize(width: unit * (index == 0 ? 4 : 1), height: nil)).height
      }.max() ?? 0
    return CGSize(width: width, height: height)
  }

  func placeSubviews(
    in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
  ) {
    let unit = max(0, bounds.width - spacing) / 5
    for (index, view) in subviews.enumerated() {
      view.place(
        at: CGPoint(x: bounds.minX + (index == 0 ? 0 : unit * 4 + spacing), y: bounds.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: unit * (index == 0 ? 4 : 1), height: nil))
    }
  }
}
