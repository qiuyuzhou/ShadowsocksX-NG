import Foundation

/// 设置工作流 module（issue #44）：设置窗口的唯一 UI-facing seam。以平坦的
/// UI 形状草稿为编辑态唯一 source of truth，向 UI 只提供字段归位的校验问题、
/// 端口 field state、保存门禁/脏态/提交中/失败文案投影、统一确认事实与具名
/// typed command。视图不再拆装 Domain 枚举、翻译占用事实、推导门禁或自备
/// 确认文案；alert、sheet 与窗口状态仍由 UI 持有。登录启动项是独立偏好域，
/// 不经本 module。
///
/// 内部沿用既有深 module：`ProxySettings` 的点名校验、`ProxyPortSemantics` 的
/// 端口互异/建议算法、`PortChangeNotice` 的 PAC 失效判定与 `PortOccupancyProbing`
/// 探测缝（编辑期尽力而为的即时提示，激活成败仍以 runtime 健康门禁为准）。
/// 写入侧只依赖窄 seam `SettingsCommitting`。module 不依赖 SwiftUI。
@MainActor
final class SettingsWorkflow: ObservableObject {
  /// 编辑中的 UI 形状草稿：视图按字段绑定；监听设置变化时自动重探占用。
  @Published var draft: SettingsDraft {
    didSet {
      if listenFingerprint(of: draft) != listenFingerprint(of: oldValue) {
        refreshOccupancy()
      }
    }
  }
  /// 各端口的尽力而为占用判定（非权威，只影响编辑期提示与保存门禁）。
  @Published private var occupancyByPort: [SettingsPortID: SettingsPortOccupancy] = [:]
  /// 提交/重置进行中（按钮进入进行中状态且不可重复触发）。
  @Published private(set) var isCommitting = false
  /// 最近一次提交/重置失败的点名原因（nil = 无）。
  @Published private(set) var lastFailureMessage: String?
  /// 等待用户裁定的确认事实（PAC 失效、重置偏好）；视图只持有 alert 呈现状态。
  @Published private(set) var pendingConfirmation: SettingsConfirmation?

  private let committing: SettingsCommitting
  private let occupancyProbe: PortOccupancyProbing
  /// 占用探测代际：草稿快速连续变化时只有最新一轮结果生效。
  private var occupancyGeneration = 0

  /// 触发占用重探的监听字段指纹（范围、公布地址、端口与 HTTP/UDP 开关）。
  private struct ListenFingerprint: Equatable {
    let isHostScope: Bool
    let advertisedAddress: String
    let socksPort: Int
    let httpProxyEnabled: Bool
    let httpPort: Int
    let pacPort: Int
    let udpRelayEnabled: Bool

    init(_ draft: SettingsDraft) {
      isHostScope = draft.isHostScope
      advertisedAddress = draft.advertisedAddress
      socksPort = draft.socksPort
      httpProxyEnabled = draft.httpProxyEnabled
      httpPort = draft.httpPort
      pacPort = draft.pacPort
      udpRelayEnabled = draft.udpRelayEnabled
    }
  }

  init(
    committing: SettingsCommitting,
    occupancyProbe: PortOccupancyProbing = SystemPortOccupancyProbe()
  ) {
    self.committing = committing
    self.occupancyProbe = occupancyProbe
    draft = SettingsDraftAdapter.draft(from: committing.committedSettings)
    refreshOccupancy()
  }

  // MARK: - 字段归位的校验问题

  /// 草稿点名校验问题（随 draft 变化；点名文案来自既有 Domain 错误）。
  var fieldIssues: [SettingsFieldIssue] {
    SettingsDraftAdapter.fieldIssues(from: makeSettings(from: draft).validationErrors)
  }

  /// 按字段归位的问题点名文案。
  func issues(for field: SettingsFieldID) -> [String] {
    fieldIssues.filter { $0.field == field }.map(\.message)
  }

  // MARK: - 端口 field state

  /// 端口行按统一端口标识取 field state。
  func portFieldState(for id: SettingsPortID) -> SettingsPortFieldState {
    let exception = isRuntimePortException(id)
    let occupancy = occupancyByPort[id]
    let canSuggest: Bool
    switch occupancy {
    case .occupied:
      canSuggest = !exception
    case .free, .unknown, nil:
      canSuggest = false
    }
    return SettingsPortFieldState(
      id: id,
      draftValue: draft.portValue(for: id),
      occupancy: occupancy,
      issues: issues(for: .port(id)),
      isRuntimePortException: exception,
      canSuggestFreePort: canSuggest)
  }

  /// 是否存在阻塞保存的端口占用（事实查询，呈现由视图决定）。HTTP 入站关闭
  /// 时 HTTP 端点不参与门禁。
  var hasBlockingPortOccupancy: Bool {
    SettingsPortID.allCases.contains { id in
      guard id != .http || draft.httpProxyEnabled else { return false }
      guard !isRuntimePortException(id) else { return false }
      if case .occupied = occupancyByPort[id] { return true }
      return false
    }
  }

  // MARK: - 操作区只读投影

  /// 保存门禁：校验问题清零、无阻塞性占用、且不在提交中。
  var canSave: Bool {
    fieldIssues.isEmpty && !hasBlockingPortOccupancy && !isCommitting
  }

  /// 脏态：草稿若提交会不会改变已提交快照（草稿经唯一 adapter 归一后比较，
  /// 隐藏字段里的残留文本不误报未保存修改）。
  var isDirty: Bool {
    makeSettings(from: draft) != committing.committedSettings
  }

  // MARK: - 具名 typed command

  /// 保存：门禁通过后，若 PAC 端口将变化则挂起失效确认，否则提交。
  func save() {
    guard canSave else { return }
    let proposed = makeSettings(from: draft)
    if let notice = PortChangeNotice.pacInvalidation(
      from: committing.committedSettings.listen, to: proposed.listen)
    {
      pendingConfirmation = .pacInvalidation(summary: notice)
      return
    }
    commit(proposed)
  }

  /// 用户裁定继续保存（确认 PAC 失效提示）后提交。
  func confirmPACNotice() {
    guard case .pacInvalidation = pendingConfirmation else { return }
    pendingConfirmation = nil
    guard canSave else { return }
    commit(makeSettings(from: draft))
  }

  /// 取消挂起的 PAC 失效提示：草稿保留且不提交。
  func cancelPACNotice() {
    guard case .pacInvalidation = pendingConfirmation else { return }
    pendingConfirmation = nil
  }

  /// 重置偏好：seam 裁定恒需确认，挂起重置确认事实（摘要范围与重置事务
  /// 一致）。登录启动项与快捷键意图是独立偏好域，不在此事务内。
  func reset() {
    guard !isCommitting else { return }
    pendingConfirmation = .resetPreferences(summary: Self.resetSummary)
  }

  /// 用户裁定重置后走重置提交入口：恢复出厂值并停止运行中的代理。
  func confirmReset() {
    guard case .resetPreferences = pendingConfirmation else { return }
    pendingConfirmation = nil
    guard !isCommitting else { return }
    isCommitting = true
    lastFailureMessage = nil
    Task { @MainActor in
      do {
        try await committing.resetPreferences()
        adoptCommittedSettings()
      } catch {
        lastFailureMessage = Self.presentedReason(for: error)
      }
      isCommitting = false
    }
  }

  /// 取消重置：不发生任何提交。
  func cancelReset() {
    guard case .resetPreferences = pendingConfirmation else { return }
    pendingConfirmation = nil
  }

  /// 为端口建议一个空闲端口：只把候选写进草稿对应字段，绝不替用户保存。
  func suggestFreePort(for id: SettingsPortID) {
    let listen = makeSettings(from: draft).listen
    let endpoint = SettingsDraftAdapter.endpoint(for: id)
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
      draft.setPortValue(candidate, for: id)
    }
  }

  /// 回到已提交快照：放弃未保存修改；监听设置未变时仍刷新占用，避免陈旧提示。
  func reloadFromCommitted() {
    adoptCommittedSettings()
  }

  // MARK: - 提交与占用探测（implementation，UI 不可见）

  /// 重置事务的范围摘要（story 25）：与 `resetPreferences` 的实际事务一致——
  /// 全部偏好（含端口、监听范围与 PAC 设置）回出厂值，运行中的代理停止。
  private static let resetSummary =
    "端口、监听范围和 PAC 设置等全部偏好都会恢复为出厂值，运行中的代理会停止。"

  private var committedListen: SslocalListenSettings {
    committing.committedSettings.listen
  }

  private func makeSettings(from draft: SettingsDraft) -> ProxySettings {
    SettingsDraftAdapter.settings(from: draft, preservingModeOf: committing.committedSettings)
  }

  /// 端口是否正是当前运行中的代理在用的端口（保存其他设置不会触发冲突）。
  /// 例外只影响保存门禁与提示，不改持久化；HTTP 端点还需已提交侧启用入站。
  private func isRuntimePortException(_ id: SettingsPortID) -> Bool {
    guard committing.isProxyRunning else { return false }
    let endpoint = SettingsDraftAdapter.endpoint(for: id)
    guard committedListen.configuredPort(for: endpoint) == draft.portValue(for: id) else {
      return false
    }
    return id != .http || committedListen.httpProxyEnabled
  }

  private func listenFingerprint(of draft: SettingsDraft) -> ListenFingerprint {
    ListenFingerprint(draft)
  }

  private func commit(_ proposed: ProxySettings) {
    isCommitting = true
    lastFailureMessage = nil
    Task { @MainActor in
      do {
        try await committing.updateSettings(proposed)
        adoptCommittedSettings()
      } catch {
        lastFailureMessage = Self.presentedReason(for: error)
      }
      isCommitting = false
    }
  }

  /// 提交成功或回到已提交快照：草稿回到已提交快照；监听设置未变时 didSet
  /// 不会重探，需显式刷新。
  private func adoptCommittedSettings() {
    let next = SettingsDraftAdapter.draft(from: committing.committedSettings)
    let listenUnchanged = listenFingerprint(of: draft) == listenFingerprint(of: next)
    draft = next
    if listenUnchanged {
      refreshOccupancy()
    }
  }

  private func refreshOccupancy() {
    occupancyGeneration += 1
    let generation = occupancyGeneration
    let listen = makeSettings(from: draft).listen
    let probe = occupancyProbe
    Task { @MainActor in
      let result = await Task.detached(priority: .utility) {
        Dictionary(
          uniqueKeysWithValues: SettingsPortID.allCases.map { id in
            (
              id,
              SettingsPortOccupancy(
                probe.occupancy(
                  port: listen.configuredPort(for: SettingsDraftAdapter.endpoint(for: id)),
                  bindAddress: listen.bindAddress))
            )
          })
      }.value
      guard generation == occupancyGeneration else { return }
      occupancyByPort = result
    }
  }

  private static func presentedReason(for error: Error) -> String {
    if let error = error as? ProxySettingsStoreError {
      return error.presentedReason
    }
    return String(describing: error)
  }
}
