import Combine
import Foundation

/// File reads and collection preparation run outside the UI actor; queries use
/// the prepared collection and do not rebuild semantic analysis on each keypress.
@MainActor
final class RulesWorkflow: ObservableObject {
  @Published private(set) var snapshot = RulesPageSnapshot()
  @Published private(set) var reportSource: RulesSourceSnapshot?
  private let loadCustom: @Sendable () throws -> [CustomRule]
  private let builtinSnapshots: BuiltinRuleSnapshots
  private let loadDocument: (@MainActor () throws -> CustomRuleDocument)?
  private let commitDocument: (@MainActor (CustomRuleDocument) async -> RuleDocumentCommit)?
  private var collection: RulesCollection?
  private var refreshGeneration = 0
  private var testGeneration = 0
  private let feedbackDelay: @Sendable () async throws -> Void
  private var feedbackTask: Task<Void, Never>?

  init(
    loadCustom: (@Sendable () throws -> [CustomRule])? = nil,
    loadDocument: (@MainActor () throws -> CustomRuleDocument)? = nil,
    commitDocument: (@MainActor (CustomRuleDocument) async -> RuleDocumentCommit)? = nil,
    feedbackDelay: @escaping @Sendable () async throws -> Void = {
      try await Task.sleep(for: .seconds(3))
    },
    builtinSnapshots: BuiltinRuleSnapshots? = nil,
    loadBuiltin: @escaping @Sendable (RulesSource) throws -> RuleSnapshot = { source in
      switch source {
      case .geolocationCN: try BuiltinRuleCatalog.loadGeolocationCN()
      case .chinaIPv4: try BuiltinRuleCatalog.loadChinaIPv4()
      case .gfwlist: try BuiltinRuleCatalog.loadGFWList()
      case .custom, .fixed: throw RuleSnapshotError.missing
      }
    }
  ) {
    if let loadDocument {
      self.loadDocument = loadDocument
    } else if loadCustom == nil {
      self.loadDocument = { try CustomRuleStore().loadDocument() }
    } else {
      self.loadDocument = nil
    }
    self.commitDocument = commitDocument
    self.feedbackDelay = feedbackDelay
    self.loadCustom = loadCustom ?? { try CustomRuleStore().load() }
    self.builtinSnapshots = builtinSnapshots ?? BuiltinRuleSnapshots(loader: loadBuiltin)
  }

  func refresh(retryFailedSources: Bool = false) async {
    guard !snapshot.isCommitting else { return }
    if snapshot.commitOutcome?.isSuccess == true && !snapshot.issues.isEmpty {
      dismissFeedback()
    }
    await refreshCollection(retryFailedSources: retryFailedSources)
  }

  private func refreshCollection(retryFailedSources: Bool) async {
    refreshGeneration += 1
    let generation = refreshGeneration
    invalidateAddressTest()
    snapshot.isLoading = true
    let custom = loadCustom
    let sources = await builtinSnapshots.browsingSources(retryFailures: retryFailedSources)
    let document: Result<CustomRuleDocument, Error>?
    if let loadDocument {
      do { document = .success(try loadDocument()) } catch { document = .failure(error) }
    } else {
      document = nil
    }
    let result = await Task.detached(priority: .userInitiated) {
      RulesCollection.load(
        custom: custom,
        builtin: { source in try sources[source, default: .failure(RuleSnapshotError.missing)].get()
        },
        document: document.map { saved in { try saved.get() } })
    }.value
    guard generation == refreshGeneration else { return }
    if !result.issues.isEmpty, collection != nil {
      snapshot.issues = result.issues
      snapshot.isLoading = false
      return
    }
    collection = result
    var next = snapshot
    next.version = result.version
    next.sources = result.sources
    next.issues = result.issues
    next.isLoading = false
    snapshot = applyingQuery(to: next)
  }

  var actionableSelection: Set<RuleIdentity> {
    Set(
      snapshot.rows.filter { snapshot.selection.contains($0.id) && !$0.isFixed }
        .compactMap(\.identity))
  }

  func setEnabled(_ enabled: Bool, identities: Set<RuleIdentity>) async {
    guard snapshot.isComplete, !snapshot.isCommitting,
      commitDocument != nil
    else { return }
    let allowed = Set(snapshot.rows.filter { !$0.isFixed }.compactMap(\.identity))
    let targets = identities.intersection(allowed)
    guard !targets.isEmpty else { return }
    guard let old = collection?.userDocument else { return }
    var disabled = old.disabledIdentities
    let changedCount =
      enabled
      ? targets.intersection(disabled).count : targets.subtracting(disabled).count
    if enabled { disabled.subtract(targets) } else { disabled.formUnion(targets) }
    guard disabled != old.disabledIdentities else { return }
    _ = await commit(
      CustomRuleDocument(rules: old.rules, disabledIdentities: disabled),
      operation: .enablement(enabled), changedCount: changedCount)
  }

  private func commit(
    _ document: CustomRuleDocument, operation: RulesCommitFeedback.Operation, changedCount: Int = 1
  ) async -> CustomRuleUpdateOutcome {
    guard let commitDocument else { return .busy }
    snapshot.isCommitting = true
    dismissFeedback()
    invalidateAddressTest()
    let result = await commitDocument(document)
    var next = snapshot
    if let document = result.document, let previous = collection,
      document != previous.userDocument
    {
      let updated = await Task.detached(priority: .userInitiated) {
        previous.replacingUserDocument(document)
      }.value
      collection = updated
      next = snapshot
      next.version = updated.version
      next.sources = updated.sources
      next.issues = updated.issues
      next = applyingQuery(to: next)
    } else if result.document == nil {
      next.issues = [.userDocument("Saved rule document is unavailable")]
    }
    next.isCommitting = false
    publishFeedback(result.outcome, operation: operation, changedCount: changedCount, page: next)
    return result.outcome
  }

  func dismissFeedback() {
    feedbackTask?.cancel()
    feedbackTask = nil
    snapshot.commitFeedback = nil
  }

  private func publishFeedback(
    _ outcome: CustomRuleUpdateOutcome, operation: RulesCommitFeedback.Operation, changedCount: Int,
    page: RulesPageSnapshot
  ) {
    let feedback = RulesCommitFeedback(
      outcome: outcome, operation: operation, changedCount: changedCount)
    var next = page
    next.commitFeedback = feedback
    snapshot = next
    guard outcome.isSuccess, snapshot.issues.isEmpty else { return }
    let delay = feedbackDelay
    feedbackTask = Task { [weak self] in
      do { try await delay() } catch { return }
      guard !Task.isCancelled, self?.snapshot.commitFeedback?.id == feedback.id else { return }
      self?.dismissFeedback()
    }
  }

  func setTestTarget(_ target: String) {
    guard target != snapshot.addressTest.target else { return }
    invalidateAddressTest()
    snapshot.addressTest.target = target
  }

  func testAddress() async {
    invalidateAddressTest()
    guard snapshot.isComplete, let collection else {
      snapshot.addressTest.failure = .incompleteCollection
      return
    }
    let generation = testGeneration
    let target = snapshot.addressTest.target
    snapshot.addressTest.isTesting = true
    let result = await Task.detached(priority: .userInitiated) {
      do {
        return Result<OfflineRuleMatcher.Result, OfflineRuleMatcher.Failure>.success(
          try OfflineRuleMatcher.test(collection: collection, address: target))
      } catch {
        return .failure(error as? OfflineRuleMatcher.Failure ?? .invalidTarget)
      }
    }.value
    guard generation == testGeneration, snapshot.isComplete,
      snapshot.version == collection.version
    else { return }
    snapshot.addressTest.isTesting = false
    switch result {
    case .success(let result): snapshot.addressTest.result = result
    case .failure(let failure): snapshot.addressTest.failure = failure
    }
  }

  private func invalidateAddressTest() {
    testGeneration += 1
    snapshot.addressTest = RulesAddressTest(target: snapshot.addressTest.target)
  }

  func query(_ query: RulesQuery) {
    guard query != snapshot.query else { return }
    var next = snapshot
    next.query = query
    snapshot = applyingQuery(to: next)
  }

  func select(_ ids: Set<RulesRow.SelectionID>) {
    let selection = ids.intersection(Set(snapshot.rows.map(\.id)))
    guard selection != snapshot.selection else { return }
    snapshot.selection = selection
  }

  /// Capture only on an explicit open request, independently of browsing and refresh.
  @discardableResult
  func openSourceReport(_ source: RulesSource) -> Bool {
    guard let loaded = snapshot.sources.first(where: { $0.id == source }),
      loaded.metadata != nil, loaded.conversionReport != nil
    else { return false }
    reportSource = loaded
    return true
  }

  var selectedRelationshipRow: RulesRow? {
    guard snapshot.selection.count == 1,
      let row = snapshot.rows.first(where: { snapshot.selection.contains($0.id) }),
      !row.relationships.isEmpty || row.fixedCoverage != nil
    else { return nil }
    return row
  }

  private func applyingQuery(to page: RulesPageSnapshot) -> RulesPageSnapshot {
    guard let collection else { return page }
    let query = page.query
    let search = query.search.lowercased()
    var rows = collection.rows.filter { row in
      (query.action == nil || row.action == query.action)
        && (query.source.map { row.sources.contains($0) } ?? true)
        && (query.enabled.map { row.isEnabled == $0 } ?? true)
        && (row.hasCurrentSource || (query.source == nil && query.enabled == false))
        && (search.isEmpty || row.content.lowercased().contains(search))
    }
    if query.sort == .descending { rows.reverse() }
    var next = page
    next.rows = rows
    next.selection.formIntersection(Set(rows.map(\.id)))
    return next
  }
}

extension RulesWorkflow {
  func makeCustomRuleDraft(editing id: UUID? = nil) -> CustomRuleDraft? {
    guard snapshot.isComplete, commitDocument != nil, let document = collection?.userDocument
    else { return nil }
    if let id {
      guard let rule = document.rules.first(where: { $0.id == id }) else { return nil }
      return CustomRuleDraft(
        id: id, editingID: id, version: snapshot.version,
        kind: rule.identity.match.editingKind, content: rule.identity.match.editingContent,
        action: rule.action)
    }
    return CustomRuleDraft(id: UUID(), editingID: nil, version: snapshot.version)
  }

  func previewCustomRule(_ draft: CustomRuleDraft) async -> CustomRulePreview {
    guard !snapshot.isCommitting else { return CustomRulePreview(failure: .busy) }
    guard snapshot.isComplete, let collection, collection.userDocument != nil
    else { return CustomRulePreview(failure: .incompleteCollection) }
    guard draft.version == snapshot.version else { return CustomRulePreview(failure: .staleDraft) }
    let prepared = await Task.detached(priority: .userInitiated) {
      collection.previewCustomRule(draft)
    }.value
    guard !snapshot.isCommitting else { return CustomRulePreview(failure: .busy) }
    guard snapshot.isComplete else { return CustomRulePreview(failure: .incompleteCollection) }
    guard snapshot.version == draft.version else { return CustomRulePreview(failure: .staleDraft) }
    return prepared
  }

  func saveCustomRule(_ draft: CustomRuleDraft) async -> CustomRuleSaveResult {
    let preview = await previewCustomRule(draft)
    if let failure = preview.failure { return .unavailable(failure) }
    guard snapshot.isComplete, let document = preview.document else { return .unavailable(.busy) }
    return .committed(await commit(document, operation: draft.editingID == nil ? .add : .edit))
  }
}

/// Deletion targets custom memberships, never the shared match-and-action identity.
extension RulesWorkflow {
  var deletableSelection: Set<UUID> {
    Set(snapshot.rows.filter { snapshot.selection.contains($0.id) }.flatMap(\.customIDs))
  }

  func prepareCustomRuleDeletion() -> CustomRuleDeletion? {
    guard snapshot.isComplete, !snapshot.isCommitting, commitDocument != nil,
      !deletableSelection.isEmpty
    else { return nil }
    return CustomRuleDeletion(customIDs: deletableSelection, version: snapshot.version)
  }

  func deleteCustomRules(_ confirmation: CustomRuleDeletion) async -> CustomRuleDeletionResult {
    guard !snapshot.isCommitting else { return .unavailable(.busy) }
    guard snapshot.isComplete, commitDocument != nil, let old = collection?.userDocument
    else { return .unavailable(.incompleteCollection) }
    guard confirmation.version == snapshot.version,
      !confirmation.customIDs.isEmpty,
      confirmation.customIDs.isSubset(of: Set(old.rules.map(\.id)))
    else { return .unavailable(.staleConfirmation) }
    let document = CustomRuleDocument(
      rules: old.rules.filter { !confirmation.customIDs.contains($0.id) },
      disabledIdentities: old.disabledIdentities)
    return .committed(
      await commit(
        document, operation: .delete, changedCount: confirmation.customIDs.count))
  }
}

struct CustomRuleDeletion: Equatable, Sendable {
  let customIDs: Set<UUID>
  let version: String

  fileprivate init(customIDs: Set<UUID>, version: String) {
    self.customIDs = customIDs
    self.version = version
  }
}
