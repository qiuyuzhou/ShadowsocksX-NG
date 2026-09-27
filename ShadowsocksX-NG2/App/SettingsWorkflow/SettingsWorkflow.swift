import Foundation

/// 设置工作流 module（issue #48）：设置窗口的唯一 UI-facing seam。以平坦的
/// UI 形状草稿为编辑态唯一 source of truth，向 UI 只提供字段归位的校验问题、
/// 端口 field state、保存门禁/脏态/提交中/typed outcome 与具名 async command。
/// 视图不再拆装 Domain 枚举或翻译占用事实；alert、sheet 与窗口状态仍由 UI
/// 持有。登录启动项是独立偏好域，不经本 module。
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
  /// 独立端口设置编辑器的占用事实；基于已提交的监听方式和编辑中的端口对。
  @Published private var portEditorOccupancyByPort: [SettingsPortID: SettingsPortOccupancy] = [:]
  private var portEditorOccupancyDraft: SettingsPortDraft?
  private var portEditorOccupancyGeneration = 0
  /// 提交进行中（按钮进入进行中状态且不可重复触发）。
  @Published private(set) var isCommitting = false
  /// 最近一次提交失败的 typed fact（nil = 无）。
  @Published private(set) var lastFailure: SettingsWorkflowFailure?
  /// 最近一次离散 command 的结构化结果，供 UI 观察而无需解析字符串。
  @Published private(set) var lastOutcome: SettingsCommandOutcome?

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

  /// 当前已提交的端口对；设置页摘要与编辑器入口都以此为准。
  var committedPortDraft: SettingsPortDraft {
    let listen = committing.committedSettings.listen
    return SettingsPortDraft(socksPort: listen.socksPort, httpPort: listen.httpPort)
  }

  var committedListenerMode: ListenerMode {
    committing.committedSettings.listen.listenerMode
  }

  func beginListenerModeEditing() -> ListenerMode {
    lastFailure = nil
    return committedListenerMode
  }

  /// 打开独立端口设置项时，从已提交值开始，丢弃上次编辑器探测的暂存事实。
  func beginPortSettingsEditing() -> SettingsPortDraft {
    lastFailure = nil
    portEditorOccupancyGeneration += 1
    portEditorOccupancyDraft = nil
    portEditorOccupancyByPort = [:]
    return committedPortDraft
  }

  /// 编辑器端口字段状态；监听方式取已提交设置，不受设置页其他草稿影响。
  func portFieldState(
    for id: SettingsPortID, editorDraft: SettingsPortDraft
  ) -> SettingsPortFieldState {
    let exception = isRuntimePortException(editorDraft: editorDraft)
    let occupancy =
      portEditorOccupancyDraft == editorDraft
      ? portEditorOccupancyByPort[id] : nil
    let issues = portIssues(for: editorDraft).filter { $0.field == .port(id) }
    let canSuggest: Bool
    if case .occupied? = occupancy {
      canSuggest = !exception
    } else {
      canSuggest = false
    }
    return SettingsPortFieldState(
      id: id,
      draftValue: editorDraft.portValue(for: id),
      occupancy: occupancy,
      issues: issues,
      isRuntimePortException: exception,
      canSuggestFreePort: canSuggest)
  }

  /// 刷新编辑器端口对的占用事实。旧结果不能覆盖较新的端口编辑。
  func refreshPortEditorOccupancy(for editorDraft: SettingsPortDraft) {
    portEditorOccupancyGeneration += 1
    let generation = portEditorOccupancyGeneration
    portEditorOccupancyDraft = editorDraft
    portEditorOccupancyByPort = [:]
    let listen = listenSettings(for: editorDraft)
    let facts = RuntimeListenFacts(listen: listen)
    let probe = occupancyProbe
    Task { @MainActor in
      let result = await Task.detached(priority: .utility) {
        Dictionary(
          uniqueKeysWithValues: SettingsPortID.allCases.map { id in
            let endpoint = SettingsDraftAdapter.endpoint(for: id)
            let request = PortOccupancyProbeRequest(endpoint: endpoint, listen: facts)
            return (id, SettingsPortOccupancy(probe.occupancy(for: request)))
          })
      }.value
      guard generation == portEditorOccupancyGeneration,
        portEditorOccupancyDraft == editorDraft
      else { return }
      portEditorOccupancyByPort = result
    }
  }

  /// 编辑器的保存门禁：等待占用探测完成；无效值和已知外部占用阻止保存，未知只提示。
  func canSavePortSettings(_ editorDraft: SettingsPortDraft) -> Bool {
    portIssues(for: editorDraft).isEmpty
      && hasCurrentPortEditorOccupancy(for: editorDraft)
      && blockingPortIDs(for: editorDraft).isEmpty
      && !isCommitting
  }

  /// 给编辑器中的端口生成空闲候选；只返回候选，等待用户再次保存端口对。
  @discardableResult
  func suggestFreePort(
    for id: SettingsPortID, from editorDraft: SettingsPortDraft
  ) async -> SettingsCommandOutcome {
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    let listen = listenSettings(for: editorDraft)
    let facts = RuntimeListenFacts(listen: listen)
    let endpoint = SettingsDraftAdapter.endpoint(for: id)
    let generation = portEditorOccupancyGeneration
    let probe = occupancyProbe
    let candidate = await Task.detached(priority: .utility) {
      listen.suggestedPort(for: endpoint) { port in
        let request = PortOccupancyProbeRequest(
          endpoint: endpoint, listen: facts.replacingPort(port, for: endpoint), port: port)
        if case .free = probe.occupancy(for: request) { return true }
        return false
      }
    }.value
    guard generation == portEditorOccupancyGeneration,
      portEditorOccupancyDraft == editorDraft
    else {
      return record(.rejected(.superseded))
    }
    guard let candidate else {
      return record(.rejected(.noFreePort(id)))
    }
    return record(.draftUpdated(port: id, value: candidate))
  }

  /// 单独保存 SOCKS5/HTTP 端口对，不提交设置页里其他未保存字段。
  @discardableResult
  func savePortSettings(_ editorDraft: SettingsPortDraft) async -> SettingsCommandOutcome {
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    let issues = portIssues(for: editorDraft)
    guard issues.isEmpty else {
      return record(.rejected(.validation(issues)))
    }
    guard hasCurrentPortEditorOccupancy(for: editorDraft) else {
      return record(.rejected(.inProgress))
    }
    let blockedPorts = blockingPortIDs(for: editorDraft)
    guard blockedPorts.isEmpty else {
      return record(.rejected(.occupied(blockedPorts)))
    }

    var proposed = committing.committedSettings
    proposed.listen.socksPort = editorDraft.socksPort
    proposed.listen.httpPort = editorDraft.httpPort
    return await commitPortSettings(proposed)
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

  /// 保存门禁：校验问题清零、无阻塞性占用且不在提交中。
  var canSave: Bool {
    fieldIssues.isEmpty
      && blockingPortIDs.isEmpty
      && !isCommitting
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
    guard fieldIssues.isEmpty else {
      return record(.rejected(.validation(fieldIssues)))
    }
    guard blockingPortIDs.isEmpty else {
      return record(.rejected(.occupied(blockingPortIDs)))
    }
    return await commit(makeSettings(from: draft))
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
    SettingsDraftAdapter.settings(
      from: draft, preservingUneditedFieldsOf: committing.committedSettings)
  }

  private func listenSettings(for editorDraft: SettingsPortDraft) -> SslocalListenSettings {
    var listen = committing.committedSettings.listen
    listen.socksPort = editorDraft.socksPort
    listen.httpPort = editorDraft.httpPort
    return listen
  }

  private func portIssues(for editorDraft: SettingsPortDraft) -> [SettingsFieldIssue] {
    let errors = listenSettings(for: editorDraft).portValidationErrors()
      .map(ProxySettingsValidationError.init)
    return SettingsDraftAdapter.fieldIssues(from: errors)
  }

  private func isRuntimePortException(editorDraft: SettingsPortDraft) -> Bool {
    guard let runtime = committing.runtimeListenFacts else { return false }
    return runtime == RuntimeListenFacts(listen: listenSettings(for: editorDraft))
  }

  private func blockingPortIDs(for editorDraft: SettingsPortDraft) -> [SettingsPortID] {
    SettingsPortID.allCases.filter { id in
      guard !isRuntimePortException(editorDraft: editorDraft) else { return false }
      if case .occupied? = portFieldState(for: id, editorDraft: editorDraft).occupancy {
        return true
      }
      return false
    }
  }

  private func hasCurrentPortEditorOccupancy(for editorDraft: SettingsPortDraft) -> Bool {
    portEditorOccupancyDraft == editorDraft
      && portEditorOccupancyByPort.count == SettingsPortID.allCases.count
  }

  private func commitPortSettings(_ proposed: ProxySettings) async -> SettingsCommandOutcome {
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    isCommitting = true
    lastFailure = nil
    do {
      try await committing.updateSettings(proposed)
      var nextDraft = draft
      nextDraft.socksPort = committing.committedSettings.listen.socksPort
      nextDraft.httpPort = committing.committedSettings.listen.httpPort
      draft = nextDraft
      isCommitting = false
      // Port persistence succeeded. Runtime convergence failure is owned by runtime
      // status and does not become a separate settings-page error for this item.
      lastFailure = nil
      return record(.persisted)
    } catch {
      isCommitting = false
      let failure = Self.workflowFailure(for: error)
      lastFailure = failure
      return record(.persistenceFailed(Self.persistenceFailure(for: error)))
    }
  }

  /// 例外只在当前 runtime 的完整有效监听身份与草稿身份相同时成立。
  /// 例外只影响保存门禁与提示，不改持久化。
  private func isRuntimePortException(_ id: SettingsPortID) -> Bool {
    guard let runtime = committing.runtimeListenFacts else { return false }
    return runtime == listenFacts(of: draft)
  }

  private func listenFacts(of draft: SettingsDraft) -> RuntimeListenFacts {
    SettingsDraftAdapter.listenFacts(from: draft, preservingModeOf: committing.committedSettings)
  }

  private func commit(_ proposed: ProxySettings) async -> SettingsCommandOutcome {
    guard !isCommitting else { return record(.rejected(.inProgress)) }
    isCommitting = true
    lastFailure = nil
    do {
      try await committing.updateSettings(proposed)
      adoptCommittedSettings()
      isCommitting = false
      return record(.persisted)
    } catch {
      isCommitting = false
      let failure = Self.workflowFailure(for: error)
      lastFailure = failure
      return record(.persistenceFailed(Self.persistenceFailure(for: error)))
    }
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
    return .unknown
  }
}

extension SettingsWorkflow {
  /// Save the listener mode as its own setting item. Occupancy is checked for
  /// the selected address family; unknown results do not block persistence.
  @discardableResult
  func saveListenerMode(_ mode: ListenerMode) async -> ListenerModeSaveOutcome {
    guard !isCommitting else { return .rejected(.inProgress) }
    guard mode != committedListenerMode else { return .saved(unknownOccupancy: []) }
    isCommitting = true
    lastFailure = nil

    var listen = committing.committedSettings.listen
    listen.listenerMode = mode
    let facts = RuntimeListenFacts(listen: listen)
    let runtime = committing.runtimeListenFacts
    let probe = occupancyProbe
    let results = await Task.detached(priority: .utility) {
      Dictionary(
        uniqueKeysWithValues: SettingsPortID.allCases.map { id in
          let endpoint = SettingsDraftAdapter.endpoint(for: id)
          let request = PortOccupancyProbeRequest(endpoint: endpoint, listen: facts)
          return (id, probe.occupancy(for: request))
        })
    }.value

    let occupancyContext = ListenerModeOccupancyContext(
      listenerMode: mode, proposedListen: facts, runtimeListen: runtime,
      runtimeProcessID: committing.runtimeListenerProcessID)
    let blocked = ListenerModeOccupancyGate.blockedPortIDs(
      results: results, context: occupancyContext)
    guard blocked.isEmpty else {
      isCommitting = false
      return .rejected(.occupied(blocked))
    }

    let unknown = ListenerModeOccupancyGate.unknownPortIDs(in: results)
    do {
      try await committing.updateListenerMode(mode)
      isCommitting = false
      lastFailure = nil
      refreshOccupancy()
      return .saved(unknownOccupancy: unknown)
    } catch {
      isCommitting = false
      let failure = Self.workflowFailure(for: error)
      lastFailure = failure
      return .persistenceFailed(Self.persistenceFailure(for: error))
    }
  }
}
