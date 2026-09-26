import Foundation

/// 设置工作流 module（issue #48）：设置窗口的唯一 UI-facing seam。以平坦的
/// UI 形状草稿为编辑态唯一 source of truth，向 UI 只提供字段归位的校验问题、
/// 端口 field state、保存门禁/脏态/提交中/typed outcome、统一确认事实与具名
/// async command。视图不再拆装 Domain 枚举、翻译占用事实、推导门禁或自备
/// 确认文案；alert、sheet 与窗口状态仍由 UI 持有。登录启动项是独立偏好域，
/// 不经本 module。
///
/// 内部沿用既有深 module：`ProxySettings` 的点名校验、`ProxyPortSemantics` 的
/// 端口互异/建议算法与 typed occupancy request。写入侧只依赖窄 seam
/// `SettingsCommitting`；module 不依赖 SwiftUI。
@MainActor
final class SettingsWorkflow: ObservableObject {
  /// 编辑中的 UI 形状草稿：视图按字段绑定；监听设置变化时自动重探占用。
  @Published var draft: SettingsDraft {
    didSet {
      if listenFacts(of: draft) != listenFacts(of: oldValue) {
        refreshOccupancy()
      }
    }
  }

  /// 各端口的尽力而为占用判定（非权威，只影响编辑期提示与保存门禁）。
  @Published private var occupancyByPort: [SettingsPortID: SettingsPortOccupancy] = [:]
  /// 提交/重置进行中（按钮进入进行中状态且不可重复触发）。
  @Published private(set) var isCommitting = false
  /// 最近一次提交/重置失败的 typed fact（nil = 无）。
  @Published private(set) var lastFailure: SettingsWorkflowFailure?
  /// 最近一次离散 command 的结构化结果，供 UI 观察而无需解析字符串。
  @Published private(set) var lastOutcome: SettingsCommandOutcome?
  /// 等待用户裁定的确认事实（重置偏好）；视图只持有 alert 呈现状态。
  @Published private(set) var pendingConfirmation: SettingsConfirmation?

  private let committing: SettingsCommitting
  private let occupancyProbe: PortOccupancyProbing
  /// 占用探测代际：草稿快速连续变化时只有最新一轮结果生效。
  private var occupancyGeneration = 0

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

  /// 按字段归位的问题事实；文案由 presentation edge 派生。
  func issues(for field: SettingsFieldID) -> [SettingsFieldIssue] {
    fieldIssues.filter { $0.field == field }
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

  /// 明确阻塞保存的端口。
  var blockingPortIDs: [SettingsPortID] {
    SettingsPortID.allCases.filter { id in
      guard !isRuntimePortException(id) else { return false }
      if case .occupied = occupancyByPort[id] { return true }
      return false
    }
  }

  /// 是否存在阻塞保存的端口占用（事实查询，呈现由视图决定）。
  var hasBlockingPortOccupancy: Bool { !blockingPortIDs.isEmpty }

  // MARK: - 操作区只读投影

  /// 保存门禁：校验问题清零、无阻塞性占用、不在提交中且没有待裁定确认。
  var canSave: Bool {
    fieldIssues.isEmpty
      && blockingPortIDs.isEmpty
      && !isCommitting
      && pendingConfirmation == nil
  }

  /// 脏态：草稿若提交会不会改变已提交快照（草稿经唯一 adapter 归一后比较，
  /// 隐藏字段里的残留文本不误报未保存修改）。
  var isDirty: Bool {
    makeSettings(from: draft) != committing.committedSettings
  }

  // MARK: - 具名 typed async commands

  /// 保存：先返回 typed gate rejection，否则等待 persistence seam 完成，
  /// 并把 runtime convergence 独立放进结果。
  @discardableResult
  func save() async -> SettingsCommandOutcome {
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    guard pendingConfirmation == nil else {
      return record(.rejected(.confirmationPending))
    }
    guard fieldIssues.isEmpty else {
      return record(.rejected(.validation(fieldIssues)))
    }
    guard blockingPortIDs.isEmpty else {
      return record(.rejected(.occupied(blockingPortIDs)))
    }
    return await commit(makeSettings(from: draft))
  }

  /// 重置偏好：seam 裁定恒需确认，挂起重置确认事实（摘要范围与重置事务
  /// 一致）。登录启动项与快捷键意图是独立偏好域，不在此事务内。
  @discardableResult
  func reset() async -> SettingsCommandOutcome {
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    guard pendingConfirmation == nil else {
      return record(.rejected(.confirmationPending))
    }
    pendingConfirmation = .resetPreferences
    return record(.confirmationRequired(.resetPreferences))
  }

  /// 用户裁定重置后走重置提交入口：恢复出厂值并停止运行中的代理。
  @discardableResult
  func confirmReset() async -> SettingsCommandOutcome {
    guard case .resetPreferences = pendingConfirmation else {
      return record(.rejected(.noPendingConfirmation))
    }
    pendingConfirmation = nil
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    isCommitting = true
    lastFailure = nil
    do {
      let runtime = try await committing.resetPreferences()
      adoptCommittedSettings()
      isCommitting = false
      return record(persistedOutcome(for: runtime))
    } catch {
      isCommitting = false
      let failure = Self.workflowFailure(for: error)
      lastFailure = failure
      return record(.persistenceFailed(Self.persistenceFailure(for: error)))
    }
  }

  /// 取消重置：不发生任何提交。
  @discardableResult
  func cancelReset() async -> SettingsCommandOutcome {
    guard case .resetPreferences = pendingConfirmation else {
      return record(.rejected(.noPendingConfirmation))
    }
    pendingConfirmation = nil
    return record(.confirmationCancelled)
  }

  /// 为端口建议一个空闲端口：只把候选写进草稿对应字段，绝不替用户保存。
  @discardableResult
  func suggestFreePort(for id: SettingsPortID) async -> SettingsCommandOutcome {
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    let listen = makeSettings(from: draft).listen
    let facts = RuntimeListenFacts(listen: listen)
    let endpoint = SettingsDraftAdapter.endpoint(for: id)
    let generation = occupancyGeneration
    let probe = occupancyProbe
    let candidate = await Task.detached(priority: .utility) {
      listen.suggestedPort(for: endpoint) { port in
        let request = PortOccupancyProbeRequest(
          endpoint: endpoint, listen: facts.replacingPort(port, for: endpoint), port: port)
        if case .free = probe.occupancy(for: request) { return true }
        return false
      }
    }.value
    guard generation == occupancyGeneration else {
      return record(.rejected(.superseded))
    }
    guard let candidate else {
      return record(.rejected(.noFreePort(id)))
    }
    draft.setPortValue(candidate, for: id)
    return record(.draftUpdated(port: id, value: candidate))
  }

  /// 回到已提交快照：放弃未保存修改；监听设置未变时仍刷新占用，避免陈旧提示。
  @discardableResult
  func reloadFromCommitted() async -> SettingsCommandOutcome {
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    adoptCommittedSettings()
    return record(.reloaded)
  }
}

extension SettingsWorkflow {
  // MARK: - 提交与占用探测（implementation，UI 不可见）

  private func makeSettings(from draft: SettingsDraft) -> ProxySettings {
    SettingsDraftAdapter.settings(from: draft, preservingModeOf: committing.committedSettings)
  }

  /// 例外只在当前 runtime 的完整有效监听身份与草稿身份相同时成立。
  /// 例外只影响保存门禁与提示，不改持久化。
  private func isRuntimePortException(_ id: SettingsPortID) -> Bool {
    guard let runtime = committing.runtimeListenFacts else { return false }
    return runtime == listenFacts(of: draft)
  }

  private func listenFacts(of draft: SettingsDraft) -> RuntimeListenFacts {
    SettingsDraftAdapter.listenFacts(from: draft)
  }

  private func commit(_ proposed: ProxySettings) async -> SettingsCommandOutcome {
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    isCommitting = true
    lastFailure = nil
    do {
      let runtime = try await committing.updateSettings(proposed)
      adoptCommittedSettings()
      isCommitting = false
      return record(persistedOutcome(for: runtime))
    } catch {
      isCommitting = false
      let failure = Self.workflowFailure(for: error)
      lastFailure = failure
      return record(.persistenceFailed(Self.persistenceFailure(for: error)))
    }
  }

  private func persistedOutcome(for runtime: SettingsRuntimeOutcome) -> SettingsCommandOutcome {
    if case .failed(let failure) = runtime {
      lastFailure = .runtime(failure)
    } else {
      lastFailure = nil
    }
    return .persisted(runtime: runtime)
  }

  /// 提交成功或回到已提交快照：草稿回到已提交快照；监听设置未变时 didSet
  /// 不会重探，需显式刷新。
  private func adoptCommittedSettings() {
    let next = SettingsDraftAdapter.draft(from: committing.committedSettings)
    let listenUnchanged = listenFacts(of: draft) == listenFacts(of: next)
    draft = next
    if listenUnchanged {
      refreshOccupancy()
    }
  }

  private func refreshOccupancy() {
    occupancyGeneration += 1
    let generation = occupancyGeneration
    let listen = listenFacts(of: draft)
    let probe = occupancyProbe
    Task { @MainActor in
      let result = await Task.detached(priority: .utility) {
        Dictionary(
          uniqueKeysWithValues: SettingsPortID.allCases.map { id in
            let endpoint = SettingsDraftAdapter.endpoint(for: id)
            let request = PortOccupancyProbeRequest(endpoint: endpoint, listen: listen)
            return (id, SettingsPortOccupancy(probe.occupancy(for: request)))
          })
      }.value
      guard generation == occupancyGeneration else { return }
      occupancyByPort = result
    }
  }

  private func record(_ outcome: SettingsCommandOutcome) -> SettingsCommandOutcome {
    lastOutcome = outcome
    return outcome
  }

  private static func persistenceFailure(for error: Error) -> SettingsPersistenceFailure {
    if let error = error as? ProxySettingsStoreError {
      return .store(error)
    }
    return .unknown
  }

  private static func workflowFailure(for error: Error) -> SettingsWorkflowFailure {
    if let error = error as? ProxySettingsStoreError {
      return .store(error)
    }
    if let error = error as? ProxyModeError {
      return .mode(error)
    }
    return .unknown
  }
}
