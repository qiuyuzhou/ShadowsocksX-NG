import SwiftUI

/// 设置分区（issue #33/#44，地图 #52 票 #57）：按原型重排为常规 / 代理端点 /
/// 高级三张分组卡，行式呈现（主文案 + 次说明 + 行尾控件）；保存是表单级提交
/// 动作，固定在本视图内容顶部行（不进窗口工具栏，避免动作与表单脱节）。
/// 字段绑定编辑 workflow 的扁平 UI-shaped draft；issues 按字段渲染；端口行读
/// typed field state；登录项开关绑定独立控制器。
struct SettingsView: View {
  @ObservedObject var workflow: SettingsWorkflow
  @ObservedObject var loginController: LaunchAtLoginController
  @State private var portSettingsEditor: PortSettingsEditorSession?

  var body: some View {
    VStack(spacing: 0) {
      commitActionsRow
      Form {
        generalSection
        endpointSection
        advancedSection
      }
      .formStyle(.grouped)
    }
    .padding(.leading, 20)
    .padding(.trailing, 24)
    .onAppear {
      Task { _ = await workflow.reloadFromCommitted() }
    }
    .sheet(item: $portSettingsEditor) { session in
      PortSettingsEditorSheet(workflow: workflow, initialDraft: session.initialDraft)
    }
  }

  // MARK: - 提交动作行（内容顶部，固定不随表单滚动）

  /// 保存（原壳动作槽位，票 #57）：表单级提交动作与表单同置；保存走 Return
  /// 默认键位。
  private var commitActionsRow: some View {
    HStack(spacing: 8) {
      Spacer(minLength: 0)
      Button(workflow.isCommitting ? "保存中…" : "保存设置") {
        Task { _ = await workflow.save() }
      }
      .keyboardShortcut(.defaultAction)
      .disabled(!workflow.canSave)
    }
    .padding(.top, 12)
    .padding(.bottom, 8)
  }

  // MARK: - 常规

  private var generalSection: some View {
    Section {
      VStack(alignment: .leading, spacing: 4) {
        Toggle(
          isOn: Binding(
            get: { loginController.isEnabled },
            set: { loginController.setEnabled($0) })
        ) {
          settingCopy("登录时启动 ShadowsocksX-NG", note: "启动菜单栏应用，不会自动开启代理")
        }
        .toggleStyle(.switch)
        if loginController.requiresApproval {
          Text("请在系统设置 → 登录项 → 允许在后台运行中批准 ShadowsocksX-NG。")
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        if let loginError = loginController.errorMessage {
          Text(loginError)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }
      .padding(.vertical, 4)
      settingRow("超时", note: "连接超时秒数（1–86400）") {
        Stepper(value: $workflow.draft.timeoutSeconds, in: 1...86_400) {
          Text("\(workflow.draft.timeoutSeconds) 秒")
            .monospacedDigit()
        }
        .frame(maxWidth: 160, alignment: .trailing)
      }
      issuesRow(.timeoutSeconds)
      Toggle(isOn: $workflow.draft.verboseLogging) {
        settingCopy("详细日志（verbose）", note: "仅在需要排障时临时启用")
      }
      .toggleStyle(.switch)
    } header: {
      sectionHeader("常规", subtitle: "应用启动与常用代理行为")
    }
  }

  // MARK: - 代理端点

  private var endpointSection: some View {
    Section {
      if let failure = workflow.lastFailure {
        Label(failure.presentableMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote)
          .foregroundStyle(.red)
      }
      settingRow("监听范围") {
        Picker("监听范围", selection: $workflow.draft.isHostScope) {
          Text("仅本机").tag(false)
          Text("局域网").tag(true)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 170)
      }
      if workflow.draft.isHostScope {
        VStack(alignment: .leading, spacing: 8) {
          LabeledContent {
            TextField("对外公布的 IPv4 地址", text: $workflow.draft.advertisedAddress)
              .textFieldStyle(.roundedBorder)
              .frame(width: 170)
          } label: {
            settingCopy("对外公布的地址")
          }
          issuesRow(.advertisedAddress)
          if workflow.draft.advertisedAddress.isEmpty {
            Text("请输入本机可路由的局域网 IPv4 地址。")
              .font(.caption)
              .foregroundStyle(.red)
          }
          Label(
            "局域网模式会把无鉴权的代理端口开放给局域网；请确认防火墙允许所需程序，并只在可信网络使用。",
            systemImage: "exclamationmark.triangle"
          )
          .font(.caption)
          .foregroundStyle(.orange)
          Text(
            "若状态显示防火墙阻止，请前往系统设置 → 网络 → 防火墙 → 选项，允许 ShadowsocksX-NG2Agent 接收入站连接。"
          )
          .font(.caption)
          .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
      }
      portSettingsRow
    } header: {
      sectionHeader("代理端点", subtitle: "监听范围和本地服务端口", trailing: "不会自动换端口")
    }
  }

  // MARK: - 高级

  private var advancedSection: some View {
    Section {
      TextField(
        "绕过列表", text: $workflow.draft.proxyExceptions,
        prompt: Text("127.0.0.1, 192.168.0.0/16, localhost …"))
      Text("逗号或空格分隔域名，这些目标不走代理。")
        .font(.caption)
        .foregroundStyle(.secondary)
      if workflow.hasBlockingPortOccupancy {
        Label("检测到端口已被占用；请在「端口设置」中选择建议空闲端口并保存。", systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      if workflow.isDirty {
        Label("存在未保存的修改；点击顶部「保存设置」生效。", systemImage: "pencil")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    } header: {
      sectionHeader("高级", subtitle: "细化系统代理行为")
    }
  }

  // MARK: - 呈现组件

  /// 分组卡标题行：标题 + 副题 + 可选尾随徽标（票 #57）。
  private func sectionHeader(_ title: String, subtitle: String, trailing: String? = nil)
    -> some View
  {
    HStack(alignment: .firstTextBaseline) {
      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(subtitle)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 12)
      if let trailing {
        Text(trailing)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.tint)
          .padding(.horizontal, 8)
          .padding(.vertical, 3)
          .background(Color.accentColor.opacity(0.12), in: Capsule())
      }
    }
    .padding(.vertical, 2)
  }

  /// 主文案 + 可选次说明（票 #57 原型行式；代理端点区不配次说明）。
  private func settingCopy(_ title: String, note: String? = nil) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.body)
      if let note {
        Text(note)
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  /// 行式布局：左侧文案，右侧控件（票 #57）。
  private func settingRow<Control: View>(
    _ title: String, note: String? = nil, @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(spacing: 16) {
      settingCopy(title, note: note)
      Spacer(minLength: 16)
      control()
    }
  }
}

// MARK: - 端口设置摘要与编辑框

extension SettingsView {
  fileprivate var portSettingsRow: some View {
    let ports = workflow.committedPortDraft
    return settingRow("端口设置") {
      Button {
        portSettingsEditor = PortSettingsEditorSession(
          initialDraft: workflow.beginPortSettingsEditing())
      } label: {
        HStack(spacing: 8) {
          Text("SOCKS5 \(ports.socksPort) / HTTP \(ports.httpPort)")
            .monospacedDigit()
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
        }
      }
      .buttonStyle(.bordered)
      .accessibilityLabel("端口设置")
      .accessibilityValue("SOCKS5 \(ports.socksPort)，HTTP 代理 \(ports.httpPort)")
    }
  }

  fileprivate func issuesRow(_ field: SettingsFieldID) -> some View {
    ForEach(workflow.issues(for: field), id: \.self) { issue in
      Text(AppPresentation.message(for: issue))
        .font(.caption)
        .foregroundStyle(.red)
    }
  }
}

private struct PortSettingsEditorSession: Identifiable {
  let id = UUID()
  let initialDraft: SettingsPortDraft
}

private struct PortSettingsEditorSheet: View {
  @ObservedObject var workflow: SettingsWorkflow
  @Environment(\.dismiss) private var dismiss
  @State private var draft: SettingsPortDraft

  init(workflow: SettingsWorkflow, initialDraft: SettingsPortDraft) {
    self.workflow = workflow
    _draft = State(initialValue: initialDraft)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("端口设置")
        .font(.title2)
      Text("端口范围为 1000–65535，SOCKS5 与 HTTP 代理端口必须不同。")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 14) {
        portField(.socks, title: "SOCKS 代理端口")
        portField(.http, title: "HTTP 代理端口")
      }

      if let failure = workflow.lastFailure {
        Label(failure.presentableMessage, systemImage: "exclamationmark.triangle.fill")
          .font(.footnote)
          .foregroundStyle(.red)
      }

      HStack {
        Spacer()
        Button("取消", role: .cancel) {
          dismiss()
        }
        .keyboardShortcut(.cancelAction)
        .disabled(workflow.isCommitting)

        Button(workflow.isCommitting ? "保存中…" : "保存") {
          Task {
            if case .persisted = await workflow.savePortSettings(draft) {
              dismiss()
            }
          }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!workflow.canSavePortSettings(draft))
      }
    }
    .padding(24)
    .frame(width: 460)
    .interactiveDismissDisabled(workflow.isCommitting)
    .task(id: draft) {
      workflow.refreshPortEditorOccupancy(for: draft)
    }
  }

  private func portField(_ id: SettingsPortID, title: String) -> some View {
    let state = workflow.portFieldState(for: id, editorDraft: draft)
    return VStack(alignment: .leading, spacing: 5) {
      HStack(spacing: 16) {
        Text(title)
        Spacer(minLength: 12)
        TextField(title, value: portBinding(for: id), format: .number.grouping(.never))
          .textFieldStyle(.roundedBorder)
          .multilineTextAlignment(.trailing)
          .monospacedDigit()
          .frame(width: 112)
          .disabled(workflow.isCommitting)
      }

      ForEach(state.issues, id: \.self) { issue in
        Text(AppPresentation.message(for: issue))
          .font(.caption)
          .foregroundStyle(.red)
      }

      if let occupancy = occupancyMessage(for: state) {
        Text(occupancy)
          .font(.caption)
          .foregroundStyle(occupancyColor(for: state))
      }

      if state.canSuggestFreePort {
        Button("建议空闲端口") {
          Task {
            let outcome = await workflow.suggestFreePort(for: id, from: draft)
            if case .draftUpdated(let port, let value) = outcome {
              draft.setPortValue(value, for: port)
            }
          }
        }
        .font(.caption)
        .disabled(workflow.isCommitting)
      }
    }
  }

  private func portBinding(for id: SettingsPortID) -> Binding<Int> {
    Binding(
      get: { draft.portValue(for: id) },
      set: { draft.setPortValue($0, for: id) })
  }

  private func occupancyMessage(for state: SettingsPortFieldState) -> String? {
    guard let occupancy = state.occupancy else { return nil }
    switch occupancy {
    case .free:
      return nil
    case .occupied(let occupier):
      if state.isRuntimePortException {
        return "当前代理正在使用此端口"
      }
      return "当前端口已占用" + (occupier.map { "（" + $0 + "）" } ?? "")
    case .unknown(let detail):
      return "端口状态无法确定：" + detail
    }
  }

  private func occupancyColor(for state: SettingsPortFieldState) -> Color {
    guard let occupancy = state.occupancy else { return .secondary }
    switch occupancy {
    case .free, .unknown:
      return .secondary
    case .occupied:
      return state.isRuntimePortException ? .secondary : .orange
    }
  }
}
