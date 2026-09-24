import SwiftUI

/// 设置分区（issue #33/#44，地图 #52 票 #57）：按原型重排为常规 / 代理端点 /
/// 高级三张分组卡，行式呈现（主文案 + 次说明 + 行尾控件）；保存/恢复默认动作
/// 在分区头动作槽位（由主窗口壳提供，确认弹窗仍由本视图的 alert 呈现）。
/// 字段绑定编辑 workflow 的扁平 UI-shaped draft；issues 按字段渲染；端口行读
/// typed field state；是否需要确认及摘要来自 seam 的统一事实；登录项开关
/// 绑定独立控制器。
struct SettingsView: View {
  @ObservedObject var workflow: SettingsWorkflow
  @ObservedObject var loginController: LaunchAtLoginController

  var body: some View {
    Form {
      generalSection
      endpointSection
      advancedSection
    }
    .formStyle(.grouped)
    .padding(.leading, 20)
    .padding(.trailing, 24)
    .onAppear {
      Task { _ = await workflow.reloadFromCommitted() }
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
      Toggle(isOn: $workflow.draft.udpRelayEnabled) {
        settingCopy("启用 UDP 中继", note: "为支持 UDP 的服务器转发数据报")
      }
      .toggleStyle(.switch)
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
      settingRow("监听范围", note: listenScopeNote) {
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
            settingCopy("对外公布的地址", note: "本机可路由的局域网 IPv4 地址")
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
      portRow(.socks, title: "SOCKS5 端口", note: "系统全局模式使用")
      Toggle(isOn: $workflow.draft.httpProxyEnabled) {
        settingCopy("启用 HTTP 代理", note: "可单独关闭 HTTP 监听")
      }
      .toggleStyle(.switch)
      portRow(.http, title: "HTTP 代理端口", note: "可单独关闭 HTTP 监听")
        .disabled(!workflow.draft.httpProxyEnabled)
      portRow(.pac, title: "PAC 端口", note: "分享出去的 PAC URL 会包含此端口")
    } header: {
      sectionHeader("代理端点", subtitle: "监听范围和本地服务端口", trailing: "不会自动换端口")
    }
  }

  private var listenScopeNote: String {
    workflow.draft.isHostScope ? "局域网 · 对外公布地址" : "仅本机 · 127.0.0.1"
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
      TextField("GFW List URL", text: $workflow.draft.gfwListURL, prompt: Text("https://…"))
      issuesRow(.gfwListURL)
      Text("远程内容只保存 URL；本设置页不负责远程内容校验或自动更新。")
        .font(.caption)
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 6) {
        settingCopy("PAC 用户规则", note: "仅以 @@ 开头的域名例外规则会生成 DIRECT；其他规则保持默认代理链")
        TextEditor(text: $workflow.draft.pacUserRules)
          .font(.system(.body, design: .monospaced))
          .frame(minHeight: 110)
          .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
      }
      .padding(.vertical, 4)
      if workflow.hasBlockingPortOccupancy {
        Label("检测到端口已被占用；请先使用对应的「建议空闲端口」，再保存设置。", systemImage: "exclamationmark.triangle")
          .font(.footnote)
          .foregroundStyle(.orange)
      }
      if workflow.isDirty {
        Label("存在未保存的修改；点击分区头「保存设置」生效。", systemImage: "pencil")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
    } header: {
      sectionHeader("高级", subtitle: "细化系统代理与 PAC 规则")
    }
  }

  // MARK: - 呈现组件

  /// 分区头：标题 + 副题 + 可选尾随徽标（票 #57）。
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

  /// 主文案 + 次说明（票 #57 原型行式）。
  private func settingCopy(_ title: String, note: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title)
        .font(.body)
      Text(note)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
  }

  /// 行式布局：左侧文案，右侧控件（票 #57）。
  private func settingRow<Control: View>(
    _ title: String, note: String, @ViewBuilder control: () -> Control
  ) -> some View {
    HStack(spacing: 16) {
      settingCopy(title, note: note)
      Spacer(minLength: 16)
      control()
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
        confirm: { Task { _ = await workflow.confirmPACNotice() } },
        cancel: { Task { _ = await workflow.cancelPACNotice() } })
    case .resetPreferences:
      ConfirmationPresentation(
        title: "重置所有偏好？",
        confirmTitle: "重置",
        confirmRole: .destructive,
        confirm: { Task { _ = await workflow.confirmReset() } },
        cancel: { Task { _ = await workflow.cancelReset() } })
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

// MARK: - 端口行（同文件扩展，保持 private 访问）

extension SettingsView {
  private func portRow(_ id: SettingsPortID, title: String, note: String) -> some View {
    let state = workflow.portFieldState(for: id)
    return settingRow(title, note: note) {
      VStack(alignment: .trailing, spacing: 4) {
        TextField(
          title,
          value: portBinding(for: id),
          format: .number.grouping(.never)
        )
        .textFieldStyle(.roundedBorder)
        .labelsHidden()
        .multilineTextAlignment(.trailing)
        .frame(width: 96)
        ForEach(Array(state.issues.enumerated()), id: \.offset) { _, issue in
          Text(AppPresentation.message(for: issue))
            .font(.caption)
            .foregroundStyle(.red)
            .frame(width: 220, alignment: .trailing)
        }
        if let occupancy = state.occupancy {
          Text(occupancyText(occupancy, state: state))
            .font(.caption)
            .foregroundStyle(occupancyColor(occupancy))
            .frame(width: 220, alignment: .trailing)
        }
        if state.canSuggestFreePort {
          Button("建议空闲端口") {
            Task { _ = await workflow.suggestFreePort(for: id) }
          }
          .font(.caption)
        }
      }
    }
    .padding(.vertical, 2)
  }

  private func portBinding(for id: SettingsPortID) -> Binding<Int> {
    Binding(
      get: { workflow.draft.portValue(for: id) },
      set: { workflow.draft.setPortValue($0, for: id) })
  }

  private func issuesRow(_ field: SettingsFieldID) -> some View {
    ForEach(Array(workflow.issues(for: field).enumerated()), id: \.offset) { _, issue in
      Text(AppPresentation.message(for: issue))
        .font(.caption)
        .foregroundStyle(.red)
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

}
