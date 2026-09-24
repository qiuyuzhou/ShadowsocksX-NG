import SwiftUI

/// 服务器详情表单（issue #32/#38/#41，地图 #52 票 #55）：按原型重排为详情头
/// （图标 + 名称 + 来源说明）+ 两列表单栅格（地址/端口、加密/备注、密码全宽、
/// 插件区）+ 底部操作区（取消恢复草稿 / 保存）。表单状态经工作流的显式编辑
/// 命令解析（凭据明文仅在编辑动作中出现）；插件区为受管选择器（D10）——
/// 「无」+ 受管列表，选中受管项才显示参数输入；集外引用以显式「本版本未
/// 提供」呈现并原样保留；分享区（二维码 + 复制 ss://，显式分享命令）。
/// 订阅服务器整表只读（无底部操作区，横幅说明）。
struct ServerDetailView: View {
  let workflow: CatalogWorkflow
  let serverID: NodeID
  /// 运行时事实（活动目标标记）：由父视图从既有接缝传入，详情面不持控制器。
  let isActiveTarget: Bool
  let errors: ErrorAlertPresenter
  let clipboard: any TextClipboard

  @State private var address = ""
  @State private var port = 8388
  @State private var encryptionMethod = ""
  @State private var password = ""
  @State private var remark = ""
  @State private var pluginChoice: PluginSelection = .none
  @State private var pluginOptionsText = ""
  @State private var showPassword = false
  // 分享/二维码状态由同 module 的 ServerDetailView+Share.swift 扩展驱动。
  @State var showQR = false
  @State var qrImage: NSImage?

  private var formState: ServerEditForm? {
    workflow.serverEditForm(for: serverID)
  }

  private var isEditable: Bool {
    formState?.isEditable ?? false
  }

  private var node: CatalogTreeNode? {
    workflow.tree.node(withID: serverID)
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
    VStack(spacing: 0) {
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          detailHeader
          formContent
        }
        .padding(.leading, 28)
        .padding(.trailing, 32)
        .padding(.top, 20)
        .padding(.bottom, 24)
      }
      if isEditable {
        detailFooter
      }
    }
    .popover(isPresented: $showQR) {
      qrPopover
    }
    .onAppear(perform: loadForm)
    .onChange(of: serverID) { _, _ in loadForm() }
  }

  // MARK: - 详情头与表单

  private var detailHeader: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(alignment: .center, spacing: 12) {
        ZStack {
          RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(Color.accentColor.opacity(0.12))
          Image(systemName: "server.rack")
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.tint)
        }
        .frame(width: 38, height: 38)
        VStack(alignment: .leading, spacing: 2) {
          Text(workflow.displayName(for: serverID))
            .font(.title2.weight(.semibold))
            .lineLimit(1)
          Text(sourceDescription)
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
        Spacer(minLength: 0)
        if let node, node.isInvalid {
          Image(systemName: "exclamationmark.triangle.fill")
            .foregroundStyle(.orange)
            .help("该服务器存在已知阻塞问题，激活会被点名拒绝")
        }
      }
      .padding(.bottom, 16)
      Divider()
    }
  }

  private var sourceDescription: String {
    guard let node else { return "" }
    if node.source == .subscription {
      return "订阅节点 · 远端管理"
    }
    return isActiveTarget ? "手动服务器 · 活动目标" : "手动服务器"
  }

  @ViewBuilder
  private var formContent: some View {
    if let node, node.isInvalid {
      invalidBanner(node)
    }
    if !isEditable {
      Label("订阅节点由远端管理：连接字段只读。", systemImage: "info.circle")
        .font(.footnote)
        .foregroundStyle(.secondary)
        .padding(.top, 16)
    }
    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 18) {
      GridRow {
        column("服务器地址") {
          TextField("服务器地址", text: $address)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
        }
        column("端口") {
          TextField("端口", value: $port, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
        }
      }
      GridRow {
        column("加密方式") {
          Picker("加密方式", selection: $encryptionMethod) {
            ForEach(methodChoices, id: \.self) { Text($0).tag($0) }
          }
          .disabled(!isEditable)
        }
        column("备注") {
          TextField("备注", text: $remark)
            .textFieldStyle(.roundedBorder)
            .disabled(!isEditable)
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
            .disabled(!isEditable)
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
            plugin: formState?.plugin,
            isEditable: isEditable)
        }
        .gridCellColumns(2)
      }
    }
    .padding(.top, 20)

    shareSection
      .padding(.top, 24)
  }

  private func invalidBanner(_ node: CatalogTreeNode) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      ForEach(Array(node.invalidReasons.enumerated()), id: \.offset) { _, reason in
        Label(
          AppPresentation.message(
            for: ActivationFailure.invalidLeaf(node: node.id, reason: reason)),
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote)
        .foregroundStyle(.orange)
      }
    }
    .padding(.top, 16)
  }

  private var shareSection: some View {
    HStack(spacing: 10) {
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
      Spacer(minLength: 0)
    }
  }

  /// 底部操作区：取消恢复已保存值，保存提交草稿。
  private var detailFooter: some View {
    VStack(spacing: 0) {
      Divider()
      HStack {
        Spacer(minLength: 0)
        Button("取消") { loadForm() }
        Button("保存") { save() }
          .keyboardShortcut(.defaultAction)
      }
      .padding(.horizontal, 32)
      .padding(.vertical, 12)
    }
    .background(.bar)
  }

  // MARK: - 表单装载与提交

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
        try await workflow.updateServer(
          serverID,
          draft: ServerEditDraft(
            address: address,
            port: port,
            encryptionMethod: encryptionMethod,
            password: password,
            remark: remark,
            plugin: pluginChoice,
            pluginOptions: pluginOptionsText))
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
