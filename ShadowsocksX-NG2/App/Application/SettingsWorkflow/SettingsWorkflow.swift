import Foundation

/// Settings item editors read the committed snapshot and submit one item at a time.
/// The module exposes validation, occupancy facts, shared commit state, and typed
/// commands; editor-local drafts and presentation state remain in the UI.
///
/// Writes depend on the narrow `SettingsCommitting` seam. The module does not
/// depend on SwiftUI, persistence formats, or runtime convergence details.
@MainActor
final class SettingsWorkflow: ObservableObject {
  /// Occupancy facts for the current port editor draft. They are advisory; the
  /// authoritative bind check still belongs to runtime startup.
  @Published private var portEditorOccupancyByPort: [SettingsPortID: SettingsPortOccupancy] = [:]
  private var portEditorOccupancyDraft: SettingsPortDraft?
  private var portEditorOccupancyGeneration = 0

  /// Shared gate that prevents concurrent saves across setting items.
  @Published private(set) var isCommitting = false
  /// Typed persistence failure for the editor to present.
  @Published private(set) var lastFailure: SettingsWorkflowFailure?

  private let committing: SettingsCommitting
  private let occupancyProbe: PortOccupancyProbing

  init(
    committing: SettingsCommitting,
    occupancyProbe: PortOccupancyProbing = SystemPortOccupancyProbe()
  ) {
    self.committing = committing
    self.occupancyProbe = occupancyProbe
  }

  /// Current committed port pair; editors start from this snapshot.
  var committedPortDraft: SettingsPortDraft {
    let listen = committing.committedSettings.listen
    return SettingsPortDraft(socksPort: listen.socksPort, httpPort: listen.httpPort)
  }

  var committedListenerMode: ListenerMode {
    committing.committedSettings.listen.listenerMode
  }

  var committedProxyExceptionCount: Int {
    committing.committedSettings.proxyExceptionList.count
  }

  func beginListenerModeEditing() -> ListenerMode {
    lastFailure = nil
    return committedListenerMode
  }

  func beginProxyExceptionsEditing() -> String {
    lastFailure = nil
    return committing.committedSettings.proxyExceptions
  }

  /// Start a port editor from committed values and discard prior probe facts.
  func beginPortSettingsEditing() -> SettingsPortDraft {
    lastFailure = nil
    portEditorOccupancyGeneration += 1
    portEditorOccupancyDraft = nil
    portEditorOccupancyByPort = [:]
    return committedPortDraft
  }

  /// Field state for the port editor. Listener mode always comes from the
  /// committed snapshot, independent of other editor state.
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

  /// Refresh port occupancy facts. Results from an older editor draft are ignored.
  func refreshPortEditorOccupancy(for editorDraft: SettingsPortDraft) {
    portEditorOccupancyGeneration += 1
    let generation = portEditorOccupancyGeneration
    portEditorOccupancyDraft = editorDraft
    portEditorOccupancyByPort = [:]
    let facts = RuntimeListenFacts(listen: listenSettings(for: editorDraft))
    let probe = occupancyProbe
    Task { @MainActor in
      let result = await Task.detached(priority: .utility) {
        Dictionary(
          uniqueKeysWithValues: SettingsPortID.allCases.map { id in
            let endpoint = SettingsPortAdapter.endpoint(for: id)
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

  /// Invalid ports and known external occupancy block the save. Unknown
  /// occupancy remains advisory, and probing must finish for this exact draft.
  func canSavePortSettings(_ editorDraft: SettingsPortDraft) -> Bool {
    portIssues(for: editorDraft).isEmpty
      && hasCurrentPortEditorOccupancy(for: editorDraft)
      && blockingPortIDs(for: editorDraft).isEmpty
      && !isCommitting
  }

  /// Return an available port candidate for the editor to apply. This command
  /// never persists the candidate.
  @discardableResult
  func suggestFreePort(
    for id: SettingsPortID, from editorDraft: SettingsPortDraft
  ) async -> SettingsCommandOutcome {
    guard !isCommitting else { return .rejected(.inProgress) }
    let listen = listenSettings(for: editorDraft)
    let facts = RuntimeListenFacts(listen: listen)
    let endpoint = SettingsPortAdapter.endpoint(for: id)
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
      return .rejected(.superseded)
    }
    guard let candidate else {
      return .rejected(.noFreePort(id))
    }
    return .suggestedPort(port: id, value: candidate)
  }

  /// Save the SOCKS5 and HTTP ports as one item.
  @discardableResult
  func savePortSettings(_ editorDraft: SettingsPortDraft) async -> SettingsCommandOutcome {
    guard !isCommitting else { return .rejected(.inProgress) }
    let issues = portIssues(for: editorDraft)
    guard issues.isEmpty else {
      return .rejected(.validation(issues))
    }
    guard hasCurrentPortEditorOccupancy(for: editorDraft) else {
      return .rejected(.inProgress)
    }
    let blockedPorts = blockingPortIDs(for: editorDraft)
    guard blockedPorts.isEmpty else {
      return .rejected(.occupied(blockedPorts))
    }

    var proposed = committing.committedSettings
    proposed.listen.socksPort = editorDraft.socksPort
    proposed.listen.httpPort = editorDraft.httpPort
    return await commitPortSettings(proposed)
  }

  /// Save only user-added system-proxy exceptions.
  @discardableResult
  func saveProxyExceptions(_ rawValue: String) async -> SettingsCommandOutcome {
    guard !isCommitting else { return .rejected(.inProgress) }
    let value =
      rawValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "" : rawValue
    guard value != committing.committedSettings.proxyExceptions else {
      lastFailure = nil
      return .persisted
    }

    var proposed = committing.committedSettings
    proposed.proxyExceptions = value
    isCommitting = true
    lastFailure = nil
    do {
      try await committing.updateSettings(proposed)
      isCommitting = false
      lastFailure = nil
      return .persisted
    } catch {
      isCommitting = false
      lastFailure = Self.workflowFailure(for: error)
      return .persistenceFailed(Self.persistenceFailure(for: error))
    }
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
    return SettingsPortAdapter.fieldIssues(from: errors)
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
    guard !isCommitting else { return .rejected(.inProgress) }
    isCommitting = true
    lastFailure = nil
    do {
      try await committing.updateSettings(proposed)
      isCommitting = false
      // Persistence succeeded. Runtime convergence is owned by runtime status.
      lastFailure = nil
      return .persisted
    } catch {
      isCommitting = false
      lastFailure = Self.workflowFailure(for: error)
      return .persistenceFailed(Self.persistenceFailure(for: error))
    }
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
  /// Save listener mode as its own setting item. Occupancy is checked for the
  /// selected address family; unknown results do not block persistence.
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
          let endpoint = SettingsPortAdapter.endpoint(for: id)
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
      return .saved(unknownOccupancy: unknown)
    } catch {
      isCommitting = false
      lastFailure = Self.workflowFailure(for: error)
      return .persistenceFailed(Self.persistenceFailure(for: error))
    }
  }
}
