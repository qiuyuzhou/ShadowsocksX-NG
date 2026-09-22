import SwiftUI

/// Native macOS settings for issue #33. Pure presentation over the settings
/// workflow module: field bindings edit the module's draft, actions go through
/// typed commands, and the login-item toggle binds its own independent
/// controller. Domain decisions (validation, occupancy, save gating, the
/// PAC-invalidation notice, reset) live behind the module's seam.
struct SettingsView: View {
  @ObservedObject var workflow: SettingsWorkflow
  @ObservedObject var loginController: LaunchAtLoginController

  @State private var showResetConfirmation = false

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
    .alert("PAC 地址将失效", isPresented: pacNoticeBinding) {
      Button("继续保存") {
        workflow.confirmPACNotice()
      }
      Button("取消", role: .cancel) {
        workflow.cancelPACNotice()
      }
    } message: {
      Text(workflow.pendingPACNotice ?? "")
    }
    .alert(
      "重置所有偏好？", isPresented: $showResetConfirmation
    ) {
      Button("重置", role: .destructive) {
        workflow.reset()
      }
      Button("取消", role: .cancel) {}
    } message: {
      Text("端口、监听范围和 PAC 设置都会恢复为出厂值。")
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

      Toggle("启用 UDP 中继", isOn: $workflow.draft.listen.udpRelayEnabled)
      Stepper(value: $workflow.draft.timeoutSeconds, in: 1...86_400) {
        Text("超时：" + String(workflow.draft.timeoutSeconds) + " 秒")
      }
      Toggle("详细日志（verbose）", isOn: $workflow.draft.verboseLogging)
    }
  }

  private var advancedSection: some View {
    Section("高级") {
      Picker("监听范围", selection: scopeBinding) {
        Text("仅本机（127.0.0.1）").tag(false)
        Text("局域网（主机地址）").tag(true)
      }

      if case .host(let address) = workflow.draft.listen.scope {
        TextField("对外公布的 IPv4 地址", text: hostAddressBinding)
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
        if address.isEmpty {
          Text("请输入本机可路由的局域网 IPv4 地址。")
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      portRow(.socks, value: $workflow.draft.listen.socksPort)
      Toggle("启用 HTTP 代理", isOn: $workflow.draft.listen.httpProxyEnabled)
      portRow(.http, value: $workflow.draft.listen.httpPort)
        .disabled(!workflow.draft.listen.httpProxyEnabled)
      portRow(.pac, value: $workflow.draft.listen.pacPort)

      TextField("绕过列表（逗号或空格分隔）", text: $workflow.draft.proxyExceptions)
      TextField("外部 PAC URL（可选）", text: $workflow.draft.externalPACURL)
      TextField("GFW List URL", text: $workflow.draft.gfwListURL)
      Text("外部内容只保存 URL；本设置页不负责远程内容校验或自动更新。")
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
      if let errorMessage = workflow.errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
      }
      if !workflow.validationErrors.isEmpty {
        Text(
          workflow.validationErrors.map(\.presentedReason).joined(separator: "\n")
        )
        .font(.caption)
        .foregroundStyle(.red)
      }
      if workflow.hasOccupiedPort {
        Text("检测到端口已被占用；请先使用对应的“建议空闲端口”，再保存设置。")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      HStack {
        Spacer()
        Button("重置偏好") {
          showResetConfirmation = true
        }
        Button(workflow.isSaving ? "保存中…" : "保存") {
          workflow.save()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(workflow.isSaving || !workflow.canSave)
      }
    }
  }

  private var pacNoticeBinding: Binding<Bool> {
    Binding(
      get: { workflow.pendingPACNotice != nil },
      set: { presented in
        if !presented, workflow.pendingPACNotice != nil {
          workflow.cancelPACNotice()
        }
      })
  }
}

extension SettingsView {
  private func portRow(_ endpoint: ProxyEndpointKind, value: Binding<Int>) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      HStack {
        Text(endpoint.displayName + " 端口")
        Spacer()
        TextField(
          endpoint.displayName + " 端口",
          value: value,
          format: .number
        )
        .frame(width: 90)
        .multilineTextAlignment(.trailing)
        .labelsHidden()
      }
      if let occupancy = workflow.occupancy[endpoint] {
        Text(occupancyText(occupancy, endpoint: endpoint))
          .font(.caption)
          .foregroundStyle(occupancyColor(occupancy))
      }
      if case .occupied = workflow.occupancy[endpoint], !workflow.isCurrentRuntimePort(endpoint) {
        Button("建议空闲端口") {
          workflow.suggestPort(for: endpoint)
        }
        .font(.caption)
      }
    }
  }

  private var scopeBinding: Binding<Bool> {
    Binding(
      get: {
        if case .host = workflow.draft.listen.scope { return true }
        return false
      },
      set: { isHost in
        guard isHost else {
          workflow.draft.listen.scope = .loopback
          return
        }
        let address: String
        if case .host(let current) = workflow.draft.listen.scope {
          address = current
        } else {
          address = ""
        }
        workflow.draft.listen.scope = .host(advertisedAddress: address)
      })
  }

  private var hostAddressBinding: Binding<String> {
    Binding(
      get: {
        if case .host(let address) = workflow.draft.listen.scope { return address }
        return ""
      },
      set: { workflow.draft.listen.scope = .host(advertisedAddress: $0) })
  }

  private func occupancyText(_ occupancy: PortOccupancy, endpoint: ProxyEndpointKind) -> String {
    switch occupancy {
    case .free:
      return "当前端口可用"
    case .occupied(let occupier):
      if workflow.isCurrentRuntimePort(endpoint) {
        return "当前代理正在使用此端口，保存其他设置不会触发冲突"
      }
      return "当前端口已占用" + (occupier.map { "（" + $0 + "）" } ?? "")
    case .unknown(let detail):
      return "端口状态无法确定：" + detail
    }
  }

  private func occupancyColor(_ occupancy: PortOccupancy) -> Color {
    switch occupancy {
    case .free: .secondary
    case .occupied: .orange
    case .unknown: .secondary
    }
  }
}
