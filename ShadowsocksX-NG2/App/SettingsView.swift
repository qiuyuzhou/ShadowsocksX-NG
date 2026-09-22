import SwiftUI

/// Native macOS settings for issue #33. The view edits one local snapshot and
/// commits it through `ProxyRuntimeController`, so active runtimes receive the
/// same validation and re-expansion path as other user actions.
struct SettingsView: View {
  @ObservedObject var proxyController: ProxyRuntimeController
  @ObservedObject var loginController: LaunchAtLoginController

  @State private var draft: ProxySettings
  @State private var portOccupancy: [ProxyEndpointKind: PortOccupancy] = [:]
  @State private var errorMessage: String?
  @State private var isSaving = false
  @State private var showPACNotice = false
  @State private var pacNotice = ""
  @State private var pendingSettings: ProxySettings?
  @State private var showResetConfirmation = false

  private let occupancyProbe: PortOccupancyProbing

  init(
    proxyController: ProxyRuntimeController,
    loginController: LaunchAtLoginController,
    occupancyProbe: PortOccupancyProbing = SystemPortOccupancyProbe()
  ) {
    self.proxyController = proxyController
    self.loginController = loginController
    self.occupancyProbe = occupancyProbe
    _draft = State(initialValue: proxyController.settings)
  }

  var body: some View {
    Form {
      generalSection
      advancedSection
      actionSection
    }
    .formStyle(.grouped)
    .padding()
    .onAppear {
      draft = proxyController.settings
      refreshPortOccupancy()
    }
    .onChange(of: draft.listen.socksPort) { refreshPortOccupancy() }
    .onChange(of: draft.listen.httpPort) { refreshPortOccupancy() }
    .onChange(of: draft.listen.pacPort) { refreshPortOccupancy() }
    .alert("PAC 地址将失效", isPresented: $showPACNotice) {
      Button("继续保存") {
        guard let pendingSettings else { return }
        commit(pendingSettings)
        self.pendingSettings = nil
      }
      Button("取消", role: .cancel) {
        pendingSettings = nil
      }
    } message: {
      Text(pacNotice)
    }
    .alert(
      "重置所有偏好？", isPresented: $showResetConfirmation
    ) {
      Button("重置", role: .destructive) {
        resetPreferences()
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

      Toggle("启用 UDP 中继", isOn: $draft.listen.udpRelayEnabled)
      Stepper(value: $draft.timeoutSeconds, in: 1...86_400) {
        Text("超时：" + String(draft.timeoutSeconds) + " 秒")
      }
      Toggle("详细日志（verbose）", isOn: $draft.verboseLogging)
    }
  }

  private var advancedSection: some View {
    Section("高级") {
      Picker("监听范围", selection: scopeBinding) {
        Text("仅本机（127.0.0.1）").tag(false)
        Text("局域网（主机地址）").tag(true)
      }

      if case .host(let address) = draft.listen.scope {
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

      portRow(.socks, value: $draft.listen.socksPort)
      Toggle("启用 HTTP 代理", isOn: $draft.listen.httpProxyEnabled)
      portRow(.http, value: $draft.listen.httpPort)
        .disabled(!draft.listen.httpProxyEnabled)
      portRow(.pac, value: $draft.listen.pacPort)

      TextField("绕过列表（逗号或空格分隔）", text: $draft.proxyExceptions)
      TextField("外部 PAC URL（可选）", text: $draft.externalPACURL)
      TextField("GFW List URL", text: $draft.gfwListURL)
      Text("外部内容只保存 URL；本设置页不负责远程内容校验或自动更新。")
        .font(.caption)
        .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 6) {
        Text("PAC 用户规则")
        TextEditor(text: $draft.pacUserRules)
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
      if let errorMessage {
        Text(errorMessage)
          .foregroundStyle(.red)
      }
      if !draft.validationErrors.isEmpty {
        Text(draft.validationErrors.map(\.presentedReason).joined(separator: "\n"))
          .font(.caption)
          .foregroundStyle(.red)
      }
      if hasOccupiedPort {
        Text("检测到端口已被占用；请先使用对应的“建议空闲端口”，再保存设置。")
          .font(.caption)
          .foregroundStyle(.orange)
      }

      HStack {
        Spacer()
        Button("重置偏好") {
          showResetConfirmation = true
        }
        Button(isSaving ? "保存中…" : "保存") {
          save()
        }
        .keyboardShortcut(.defaultAction)
        .disabled(isSaving || !draft.validationErrors.isEmpty || hasOccupiedPort)
      }
    }
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
      if let occupancy = portOccupancy[endpoint] {
        Text(occupancyText(occupancy, endpoint: endpoint))
          .font(.caption)
          .foregroundStyle(occupancyColor(occupancy))
      }
      if case .occupied = portOccupancy[endpoint], !isCurrentRuntimePort(endpoint) {
        Button("建议空闲端口") {
          suggestPort(for: endpoint)
        }
        .font(.caption)
      }
    }
  }

  private var scopeBinding: Binding<Bool> {
    Binding(
      get: {
        if case .host = draft.listen.scope { return true }
        return false
      },
      set: { isHost in
        guard isHost else {
          draft.listen.scope = .loopback
          return
        }
        let address: String
        if case .host(let current) = draft.listen.scope {
          address = current
        } else {
          address = ""
        }
        draft.listen.scope = .host(advertisedAddress: address)
      })
  }

  private var hostAddressBinding: Binding<String> {
    Binding(
      get: {
        if case .host(let address) = draft.listen.scope { return address }
        return ""
      },
      set: { draft.listen.scope = .host(advertisedAddress: $0) })
  }

  private var hasOccupiedPort: Bool {
    portOccupancy.contains { endpoint, occupancy in
      guard endpoint != .http || draft.listen.httpProxyEnabled else { return false }
      guard !isCurrentRuntimePort(endpoint) else { return false }
      if case .occupied = occupancy { return true }
      return false
    }
  }

  private func isCurrentRuntimePort(_ endpoint: ProxyEndpointKind) -> Bool {
    guard StatusMenuModel.isOn(state: proxyController.state) else { return false }
    let current = proxyController.settings.listen
    guard current.configuredPort(for: endpoint) == draft.listen.configuredPort(for: endpoint) else {
      return false
    }
    return endpoint != .http || current.httpProxyEnabled
  }

  private func occupancyText(_ occupancy: PortOccupancy, endpoint: ProxyEndpointKind) -> String {
    switch occupancy {
    case .free:
      return "当前端口可用"
    case .occupied(let occupier):
      if isCurrentRuntimePort(endpoint) {
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

  private func refreshPortOccupancy() {
    let listen = draft.listen
    let probe = occupancyProbe
    Task { @MainActor in
      let result = await Task.detached(priority: .utility) {
        Dictionary(
          uniqueKeysWithValues: ProxyEndpointKind.allCases.map { endpoint in
            (
              endpoint,
              probe.occupancy(
                port: listen.configuredPort(for: endpoint), bindAddress: listen.bindAddress)
            )
          })
      }.value
      portOccupancy = result
    }
  }

  private func suggestPort(for endpoint: ProxyEndpointKind) {
    let listen = draft.listen
    let probe = occupancyProbe
    Task { @MainActor in
      let candidate = await Task.detached(priority: .utility) {
        listen.suggestedPort(for: endpoint) { port in
          if case .free = probe.occupancy(port: port, bindAddress: listen.bindAddress) {
            return true
          }
          return false
        }
      }.value
      guard let candidate else { return }
      var next = draft.listen
      switch endpoint {
      case .socks: next.socksPort = candidate
      case .http: next.httpPort = candidate
      case .pac: next.pacPort = candidate
      }
      draft.listen = next
    }
  }

  private func save() {
    guard draft.validationErrors.isEmpty, !hasOccupiedPort else { return }
    if let notice = PortChangeNotice.pacInvalidation(
      from: proxyController.settings.listen, to: draft.listen)
    {
      pendingSettings = draft
      pacNotice = notice
      showPACNotice = true
      return
    }
    commit(draft)
  }

  private func commit(_ settings: ProxySettings) {
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      do {
        try await proxyController.updateSettings(settings)
        draft = proxyController.settings
        refreshPortOccupancy()
      } catch {
        errorMessage = presentedReason(for: error)
      }
      isSaving = false
    }
  }

  private func resetPreferences() {
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      do {
        try await proxyController.resetPreferences()
        draft = proxyController.settings
        refreshPortOccupancy()
      } catch {
        errorMessage = presentedReason(for: error)
      }
      isSaving = false
    }
  }

  private func presentedReason(for error: Error) -> String {
    if let error = error as? ProxySettingsStoreError {
      return error.presentedReason
    }
    return String(describing: error)
  }
}
