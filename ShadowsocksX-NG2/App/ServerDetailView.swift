import SwiftUI

/// 服务器详情表单（issue #32）：地址、端口、加密、密码、备注可编辑（仅手动
/// 节点）；插件区本票只读展示（选择器/参数编辑归 #38）；分享区（二维码 +
/// 复制 ss://）。订阅服务器整表只读，仅树中启用开关可调。
struct ServerDetailView: View {
  let viewModel: CatalogViewModel
  let serverID: NodeID
  let proxyController: ProxyRuntimeController

  @State private var address = ""
  @State private var port = 8388
  @State private var encryptionMethod = ""
  @State private var password = ""
  @State private var remark = ""
  @State private var showPassword = false
  @State private var showQR = false
  @State private var qrImage: NSImage?

  private var formState: ServerFormState? {
    viewModel.serverFormState(for: serverID)
  }

  private var isEditable: Bool {
    formState?.isEditable ?? false
  }

  /// 常用加密方法（sslocal v1.25 支持）；目录里既有的非常见方法原样追加显示。
  private var methodChoices: [String] {
    var choices = [
      "aes-128-gcm", "aes-256-gcm", "chacha20-ietf-poly1305",
      "2022-blake3-aes-128-gcm", "2022-blake3-aes-256-gcm",
      "2022-blake3-chacha20-poly1305", "none",
    ]
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

      Section("插件（本版本只读）") {
        pluginSection
      }

      if isEditable {
        Section {
          Button("保存修改") { save() }
        }
      } else {
        Section {
          Label("订阅节点由远端管理：连接字段只读，仅树中的启用开关可调。", systemImage: "info.circle")
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

  @ViewBuilder
  private var pluginSection: some View {
    if let plugin = formState?.plugin {
      LabeledContent("插件程序", value: plugin.program)
      LabeledContent("状态") {
        if plugin.provided {
          Label("本版本提供", systemImage: "checkmark.circle.fill")
            .foregroundStyle(.green)
        } else {
          Label("本版本未提供该插件", systemImage: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("该服务器在插件可用前是无效激活候选（点名拒绝）")
        }
      }
      LabeledContent("插件参数", value: plugin.optionsPresent ? "已配置（存于钥匙串）" : "未配置")
    } else {
      LabeledContent("插件程序", value: "无")
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
          remark: remark)
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
