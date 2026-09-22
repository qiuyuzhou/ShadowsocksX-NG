import Foundation

/// 设置工作流 module（Candidate 02）：设置窗口的唯一 UI-facing seam。持有编辑
/// 草稿并隐藏端口占用探测的异步编排、保存门禁、「当前运行端口」例外、PAC 失效
/// 确认与重置事务；提交一律经 `ProxyRuntimeController.updateSettings` /
/// `resetPreferences`，与其他用户动作走相同的校验与重展开路径。登录启动项是
/// 独立偏好域，视图直连其控制器，不经本模块。确认 alert 的呈现等窗口状态由
/// UI 持有；本类不生成用户可见文案，文案来自 Domain 错误的 presentedReason。
///
/// 内部沿用既有深 module：`ProxySettings` 的点名校验、`ProxyPortSemantics` 的
/// 端口互异/建议算法、`PortChangeNotice` 的 PAC 失效判定与 `PortOccupancyProbing`
/// 探测缝（编辑期尽力而为的即时提示，激活成败仍以 runtime 健康门禁为准）。
@MainActor
final class SettingsWorkflow: ObservableObject {
  /// 编辑中的设置快照：视图经 binding 逐字段编辑；监听设置变化时自动重探占用。
  @Published var draft: ProxySettings {
    didSet {
      if oldValue.listen != draft.listen {
        refreshOccupancy()
      }
    }
  }
  /// 各端点的尽力而为占用判定（非权威，只影响编辑期提示与保存门禁）。
  @Published private(set) var occupancy: [ProxyEndpointKind: PortOccupancy] = [:]
  @Published private(set) var isSaving = false
  /// 最近一次提交/重置失败的点名原因（nil = 无）。
  @Published private(set) var errorMessage: String?
  /// 等待用户确认的 PAC 失效提示；确认后才提交草稿。
  @Published private(set) var pendingPACNotice: String?

  private let controller: ProxyRuntimeController
  private let occupancyProbe: PortOccupancyProbing
  /// 占用探测代际：草稿快速连续变化时只有最新一轮结果生效。
  private var occupancyGeneration = 0

  init(
    controller: ProxyRuntimeController,
    occupancyProbe: PortOccupancyProbing = SystemPortOccupancyProbe()
  ) {
    self.controller = controller
    self.occupancyProbe = occupancyProbe
    draft = controller.settings
  }

  /// 草稿的点名校验错误（Domain 派生，随 draft 变化）。
  var validationErrors: [ProxySettingsValidationError] {
    draft.validationErrors
  }

  /// 保存门禁：无校验错误，且没有（当前运行端口之外的）占用。
  var canSave: Bool {
    validationErrors.isEmpty && !hasOccupiedPort
  }

  /// 是否存在阻塞保存的端口占用（事实查询，呈现由视图决定）。
  var hasOccupiedPort: Bool {
    occupancy.contains { endpoint, occupancy in
      guard endpoint != .http || draft.listen.httpProxyEnabled else { return false }
      guard !isCurrentRuntimePort(endpoint) else { return false }
      if case .occupied = occupancy { return true }
      return false
    }
  }

  /// 端口是否正是当前运行中的代理在监听的端口（保存其他设置不会触发冲突）。
  func isCurrentRuntimePort(_ endpoint: ProxyEndpointKind) -> Bool {
    guard controller.state.isOn else { return false }
    let committed = controller.settings.listen
    guard committed.configuredPort(for: endpoint) == draft.listen.configuredPort(for: endpoint)
    else { return false }
    return endpoint != .http || committed.httpProxyEnabled
  }

  /// 放弃未保存的修改回到已提交快照（设置窗口重新出现时调用）。
  func reloadFromCommitted() {
    let committed = controller.settings
    let listenUnchanged = draft.listen == committed.listen
    draft = committed
    if listenUnchanged {
      refreshOccupancy()
    }
  }

  /// 为端点建议一个空闲端口：只把候选写进草稿，绝不替用户保存。
  func suggestPort(for endpoint: ProxyEndpointKind) {
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

  /// 保存：门禁通过后，若 PAC 端口将变化则挂起等待用户确认失效提示，否则提交。
  func save() {
    guard canSave else { return }
    if let notice = PortChangeNotice.pacInvalidation(
      from: controller.settings.listen, to: draft.listen)
    {
      pendingPACNotice = notice
      return
    }
    commit(draft)
  }

  /// 用户确认 PAC 失效提示后提交。
  func confirmPACNotice() {
    pendingPACNotice = nil
    guard canSave else { return }
    commit(draft)
  }

  /// 取消挂起的保存。
  func cancelPACNotice() {
    pendingPACNotice = nil
  }

  /// 重置偏好：恢复出厂值并停止运行中的代理；持久化失败保留旧值并点名。
  /// 登录启动项与快捷键意图是独立偏好域，不在此事务内。
  func reset() {
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      do {
        try await controller.resetPreferences()
        adoptCommittedSettings()
      } catch {
        errorMessage = presentedReason(for: error)
      }
      isSaving = false
    }
  }

  // MARK: - 提交与占用探测（implementation，UI 不可见）

  private func commit(_ settings: ProxySettings) {
    isSaving = true
    errorMessage = nil
    Task { @MainActor in
      do {
        try await controller.updateSettings(settings)
        adoptCommittedSettings()
      } catch {
        errorMessage = presentedReason(for: error)
      }
      isSaving = false
    }
  }

  /// 提交成功后回到已提交快照；监听设置未变时 didSet 不会重探，需显式刷新。
  private func adoptCommittedSettings() {
    let committed = controller.settings
    let listenUnchanged = draft.listen == committed.listen
    draft = committed
    if listenUnchanged {
      refreshOccupancy()
    }
  }

  private func refreshOccupancy() {
    occupancyGeneration += 1
    let generation = occupancyGeneration
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
      guard generation == occupancyGeneration else { return }
      occupancy = result
    }
  }

  private func presentedReason(for error: Error) -> String {
    if let error = error as? ProxySettingsStoreError {
      return error.presentedReason
    }
    return String(describing: error)
  }
}
