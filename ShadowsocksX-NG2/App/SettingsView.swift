import SwiftUI

/// Native macOS settings for issue #33, bound to the settings workflow seam
/// (issue #44): field bindings edit the flat UI-shaped draft, issues render
/// beside their fields from the seam's field-scoped projection, port rows read
/// typed field state, and every discrete action is a named typed command.
/// Whether a confirmation is required and its summary come from the seam's
/// unified fact; this view only owns alert presentation. The login-item toggle
/// binds its own independent controller (separate preference domain).
struct SettingsView: View {
  @ObservedObject var workflow: SettingsWorkflow
  @ObservedObject var loginController: LaunchAtLoginController

  var body: some View {
    Form {
      generalSection
      advancedSection
      actionSection
    }
    .formStyle(.grouped)
    .padding()
    .onAppear {
      workflow.reloadFromCommitted()
    }
    .alert(
      workflow.pendingConfirmation.map { confirmationPresentation(for: $0).title } ?? "",
      isPresented: confirmationBinding,
      presenting: workflow.pendingConfirmation
    ) { confirmation in
      let presentation = confirmationPresentation(for: confirmation)
      Button(
        presentation.confirmTitle, role: presentation.confirmRole, action: presentation.confirm)
      Button("取消", role: .cancel, action: presentation.cancel)
    } message: { confirmation in
      Text(AppPresentation.message(for: confirmation))
    }
  }

  private var generalSection: some View {
    Section("常规") {
      Toggle(
        "登录时启动 ShadowsocksX-NG",
        isOn: Binding(
          get: { loginController.isEnabled },
          set: { loginController.setEnabled($0) }))
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

      Toggle("启用 UDP 中继", isOn: $workflow.draft.udpRelayEnabled)
      Stepper(value: $workflow.draft.timeoutSeconds, in: 1...86_400) {
        Text("超时：" + String(workflow.draft.timeoutSeconds) + " 秒")
      }
      fieldIssues(.timeoutSeconds)
      Toggle("详细日志（verbose）", isOn: $workflow.draft.verboseLogging)
    }
  }

  private var advancedSection: some View {
    Section("高级") {
      Picker("监听范围", selection: $workflow.draft.isHostScope) {
        Text("仅本机（127.0.0.1）").tag(false)
        Text("局域网（主机地址）").tag(true)
      }

      if workflow.draft.isHostScope {
        TextField("对外公布的 IPv4 地址", text: $workflow.draft.advertisedAddress)
        fieldIssues(.advertisedAddress)
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

      portRow(.socks)
      Toggle("启用 HTTP 代理", isOn: $workflow.draft.httpProxyEnabled)
      portRow(.http)
        .disabled(!workflow.draft.httpProxyEnabled)
      portRow(.pac)

      TextField("绕过列表（逗号或空格分隔）", text: $workflow.draft.proxyExceptions)
      TextField("GFW List URL", text: $workflow.draft.gfwListURL)
      fieldIssues(.gfwListURL)
      Text("远程内容只保存 URL；本设置页不负责远程内容校验或自动更新。")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        Text("PAC 用户规则")
        TextEditor(text: $workflow.draft.pacUserRules)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 120)
          .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
        Text("仅以 @@ 开头的域名例外规则会生成 DIRECT；其他规则保持默认代理链。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
    }
  }

  private var actionSection: some View {
    Section {
      if let failure = workflow.lastFailure {
        Text(failure.presentableMessage)
          .foregroundStyle(.red)
      }
      if workflow.hasBlockingPortOccupancy {
        Text("检测到端口已被占用；请先使用对应的“建议空闲端口”，再保存设置。")
          .font(.caption)
          .foregroundStyle(.orange)
      }
      if workflow.isDirty {
        Text("存在未保存的修改。")
          .font(.caption)
          .foregroundStyle(.secondary)
      }

      HStack {
        Spacer()
        Button("重置偏好") {
          workflow.reset()
        }
        .disabled(workflow.isCommitting)
        Button(workflow.isCommitting ? "保存中…" : "保存") {
          workflow.save()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!workflow.canSave)
      }
    }
  }
}

extension SettingsView {
  private func portRow(_ id: SettingsPortID) -> some View {
    let state = workflow.portFieldState(for: id)
    return VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(title(for: id) + " 端口")
        Spacer()
        TextField(
          title(for: id) + " 端口",
          value: portBinding(for: id),
          format: .number
        )
        .frame(width: 90)
        .multilineTextAlignment(.trailing)
        .labelsHidden()
      }
      ForEach(Array(state.issues.enumerated()), id: \.offset) { _, issue in
        Text(AppPresentation.message(for: issue))
          .font(.caption)
          .foregroundStyle(.red)
      }
      if let occupancy = state.occupancy {
        Text(occupancyText(occupancy, state: state))
          .font(.caption)
          .foregroundStyle(occupancyColor(occupancy))
      }
      if state.canSuggestFreePort {
        Button("建议空闲端口") {
          workflow.suggestFreePort(for: id)
        }
        .font(.caption)
      }
    }
  }

  private func portBinding(for id: SettingsPortID) -> Binding<Int> {
    Binding(
      get: { workflow.draft.portValue(for: id) },
      set: { workflow.draft.setPortValue($0, for: id) })
  }

  private func fieldIssues(_ field: SettingsFieldID) -> some View {
    ForEach(Array(workflow.issues(for: field).enumerated()), id: \.offset) { _, issue in
      Text(AppPresentation.message(for: issue))
        .font(.caption)
        .foregroundStyle(.red)
    }
  }

  private func title(for id: SettingsPortID) -> String {
    switch id {
    case .socks: "SOCKS5"
    case .http: "HTTP"
    case .pac: "PAC"
    }
  }

  private func occupancyText(
    _ occupancy: SettingsPortOccupancy, state: SettingsPortFieldState
  ) -> String {
    switch occupancy {
    case .free:
      return "当前端口可用"
    case .occupied(let occupier):
      if state.isRuntimePortException {
        return "当前代理正在使用此端口，保存其他设置不会触发冲突"
      }
      return "当前端口已占用" + (occupier.map { "（" + $0 + "）" } ?? "")
    case .unknown(let detail):
      return "端口状态无法确定：" + detail
    }
  }

  private func occupancyColor(_ occupancy: SettingsPortOccupancy) -> Color {
    switch occupancy {
    case .free: .secondary
    case .occupied: .orange
    case .unknown: .secondary
    }
  }

  // MARK: - 确认 alert 呈现（视图只持有呈现状态，事实来自 seam）

  private struct ConfirmationPresentation {
    let title: String
    let confirmTitle: String
    let confirmRole: ButtonRole?
    let confirm: () -> Void
    let cancel: () -> Void
  }

  private func confirmationPresentation(
    for confirmation: SettingsConfirmation
  ) -> ConfirmationPresentation {
    switch confirmation {
    case .pacInvalidation:
      ConfirmationPresentation(
        title: "PAC 地址将失效",
        confirmTitle: "继续保存",
        confirmRole: nil,
        confirm: { workflow.confirmPACNotice() },
        cancel: { workflow.cancelPACNotice() })
    case .resetPreferences:
      ConfirmationPresentation(
        title: "重置所有偏好？",
        confirmTitle: "重置",
        confirmRole: .destructive,
        confirm: { workflow.confirmReset() },
        cancel: { workflow.cancelReset() })
    }
  }

  private var confirmationBinding: Binding<Bool> {
    Binding(
      get: { workflow.pendingConfirmation != nil },
      set: { presented in
        if !presented, let confirmation = workflow.pendingConfirmation {
          confirmationPresentation(for: confirmation).cancel()
        }
      })
  }
}
