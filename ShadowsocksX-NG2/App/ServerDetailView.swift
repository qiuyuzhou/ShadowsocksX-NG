import SwiftUI

/// 服务器详情表单（issue #32/#38）：连接字段与插件选择可编辑（仅手动节点）。
/// 插件区为受管选择器（D10）——「无」+ 受管列表，选中受管项才显示参数输入；
/// 集外引用以显式「本版本未提供」呈现并原样保留；分享区（二维码 + 复制 ss://）。
/// 订阅服务器整表只读。
struct ServerDetailView: View {
  let viewModel: CatalogViewModel
  let serverID: NodeID
  let proxyController: ProxyRuntimeController

  @State private var address = ""
  @State private var port = 8388
  @State private var encryptionMethod = ""
  @State private var password = ""
  @State private var remark = ""
  @State private var pluginChoice: PluginSelection = .none
  @State private var pluginOptionsText = ""
  @State private var showPassword = false
  @State private var showQR = false
  @State private var qrImage: NSImage?

  private var formState: ServerFormState? {
    viewModel.serverFormState(for: serverID)
  }

  private var isEditable: Bool {
    formState?.isEditable ?? false
  }

  /// 当前 sslocal 能力目录；目录中既有的未知方法原样追加显示，便于用户修复。
  private var methodChoices: [String] {
    var choices = EncryptionMethodCatalog.supported.sorted()
    if !encryptionMethod.isEmpty && !choices.contains(encryptionMethod) {
      choices.append(encryptionMethod)
    }
    return choices
  }

  var body: some View {
    Form {
      Section("连接") {
        TextField("地址", text: $address)
          .disabled(!isEditable)
        TextField("端口", value: $port, format: .number.grouping(.never))
          .disabled(!isEditable)
        Picker("加密方法", selection: $encryptionMethod) {
          ForEach(methodChoices, id: \.self) { Text($0).tag($0) }
        }
        .disabled(!isEditable)
        HStack {
          if showPassword {
            TextField("密码", text: $password)
              .disabled(!isEditable)
          } else {
            SecureField("密码", text: $password)
              .disabled(!isEditable)
          }
          Button {
            showPassword.toggle()
          } label: {
            Image(systemName: showPassword ? "eye.slash" : "eye")
          }
          .buttonStyle(.borderless)
          .help(showPassword ? "隐藏密码" : "显示密码")
        }
        TextField("备注", text: $remark)
          .disabled(!isEditable)
      }

      if let validation = viewModel.validation(for: serverID), !validation.isValid {
        Section("激活状态") {
          ForEach(Array(validation.issues.enumerated()), id: \.offset) { _, issue in
            Label(issue.presentedReason, systemImage: "exclamationmark.triangle.fill")
              .foregroundStyle(.orange)
          }
        }
      }

      Section("插件") {
        pluginSection
      }

      if isEditable {
        Section {
          Button("保存修改") { save() }
        }
      } else {
        Section {
          Label("订阅节点由远端管理：连接字段只读。", systemImage: "info.circle")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }

      Section("分享") {
        Button {
          copySsUri()
        } label: {
          Label("复制 ss:// 链接", systemImage: "doc.on.doc")
        }
        Button {
          generateQR()
        } label: {
          Label("二维码…", systemImage: "qrcode")
        }
        .disabled(qrPayload() == nil)
      }
    }
    .formStyle(.grouped)
    .navigationTitle(viewModel.displayName(for: serverID))
    .popover(isPresented: $showQR) {
      qrPopover
    }
    .onAppear(perform: loadForm)
    .onChange(of: serverID) { _, _ in loadForm() }
  }

  /// 受管选择器（D10）：「无」+ 受管列表；集外现有引用追加显式「本版本未提供」
  /// 项使当前状态可见。选中受管项才显示供应链事实与参数输入。
  @ViewBuilder
  private var pluginSection: some View {
    if let plugin = formState?.plugin {
      Picker("插件", selection: $pluginChoice) {
        Text("无").tag(PluginSelection.none)
        ForEach(plugin.managed, id: \.program) { info in
          Text(info.program).tag(PluginSelection.managed(program: info.program))
        }
        if case .unknown(let program) = plugin.selection {
          Text("\(program)（本版本未提供）").tag(PluginSelection.unknown(program: program))
        }
      }
      .disabled(!isEditable)

      switch pluginChoice {
      case .none:
        Text("不使用插件：生成的配置不含 plugin 字段。")
          .font(.footnote)
          .foregroundStyle(.secondary)
      case .managed(let program):
        managedPluginDetails(program: program, plugin: plugin)
      case .unknown(let program):
        unknownPluginNotice(program: program, plugin: plugin)
      }
    }
  }

  /// 选中受管项：供应链事实（来源项目、许可证、固定版本、重签）与参数输入。
  @ViewBuilder
  private func managedPluginDetails(program: String, plugin: PluginSectionState) -> some View {
    if let info = plugin.managed.first(where: { $0.program == program }) {
      LabeledContent("来源项目", value: info.project)
      LabeledContent("许可证", value: info.license)
      LabeledContent("固定版本", value: info.release)
      Text("随 app 打包，构建期经 Developer ID 重签：\(info.signIdentifier)")
        .font(.footnote)
        .foregroundStyle(.secondary)
      if !plugin.provided {
        Label(
          "受管插件可执行文件缺失：激活会被点名拒绝；请重新安装本 app。",
          systemImage: "exclamationmark.triangle.fill"
        )
        .foregroundStyle(.orange)
      }
      TextField(
        "插件参数",
        text: $pluginOptionsText,
        prompt: Text("如 mode=websocket;host=example.com（留空即无参数）")
      )
      .disabled(!isEditable)
    }
  }

  /// 集外引用（Legacy 导入/订阅带入）：原样保留并明确指出当前 app 无法提供该插件。
  @ViewBuilder
  private func unknownPluginNotice(program: String, plugin: PluginSectionState) -> some View {
    Label(
      "本版本未提供「\(program)」：引用原样保留，激活包含该服务器会被点名拒绝；可改选「无」或受管插件。",
      systemImage: "exclamationmark.triangle.fill"
    )
    .foregroundStyle(.orange)
    if plugin.optionsPresent {
      LabeledContent("插件参数", value: "已配置（存于钥匙串，原样保留）")
    }
  }

  private var qrPopover: some View {
    VStack(spacing: 12) {
      if let qrImage {
        Image(nsImage: qrImage)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 220, height: 220)
      } else {
        ProgressView()
          .frame(width: 220, height: 220)
      }
      Text("用其他设备的客户端扫描此二维码")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button("复制 ss:// 链接") { copySsUri() }
    }
    .padding(20)
  }

  private func loadForm() {
    guard let state = formState else { return }
    address = state.address
    port = state.port
    encryptionMethod = state.encryptionMethod
    password = state.password
    remark = state.remark
    pluginChoice = state.plugin.selection
    pluginOptionsText = state.plugin.options
    showPassword = false
  }

  private func save() {
    Task {
      do {
        try await viewModel.updateServer(
          serverID,
          address: address,
          port: port,
          encryptionMethod: encryptionMethod,
          password: password,
          remark: remark,
          plugin: pluginChoice,
          pluginOptions: pluginOptionsText)
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }

  private func qrPayload() -> String? {
    try? viewModel.ssUri(for: serverID)
  }

  private func copySsUri() {
    guard let uri = qrPayload() else { return }
    let board = NSPasteboard.general
    board.clearContents()
    board.setString(uri, forType: .string)
  }

  private func generateQR() {
    guard let payload = qrPayload() else { return }
    showQR = true
    Task.detached(priority: .userInitiated) {
      let image = (try? QrCodeCodec.generatePNG(for: payload)).flatMap { NSImage(data: $0) }
      await MainActor.run {
        qrImage = image
      }
    }
  }
}
