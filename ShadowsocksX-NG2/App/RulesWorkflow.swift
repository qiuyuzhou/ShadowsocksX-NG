import Combine
import Foundation

/// File reads and collection preparation run outside the UI actor; queries use
/// the prepared collection and do not rebuild semantic analysis on each keypress.
@MainActor
final class RulesWorkflow: ObservableObject {
  @Published private(set) var snapshot = RulesPageSnapshot()
  @Published private(set) var reportSource: RulesSourceSnapshot?
  private let loadCustom: @Sendable () throws -> [CustomRule]
  private let loadBuiltin: @Sendable (RulesSource) throws -> RuleSnapshot
  private let loadDocument: (@Sendable () throws -> CustomRuleDocument)?
  private let commitDocument: (@MainActor (CustomRuleDocument) async -> CustomRuleUpdateOutcome)?
  private var collection: RulesCollection?
  private var refreshGeneration = 0
  private var testGeneration = 0

  init(
    loadCustom: (@Sendable () throws -> [CustomRule])? = nil,
    loadDocument: (@Sendable () throws -> CustomRuleDocument)? = nil,
    commitDocument: (@MainActor (CustomRuleDocument) async -> CustomRuleUpdateOutcome)? = nil,
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
    self.loadCustom = loadCustom ?? { try CustomRuleStore().load() }
    self.loadBuiltin = loadBuiltin
  }

  func refresh() async {
    guard !snapshot.isCommitting else { return }
    await refreshCollection()
  }

  private func refreshCollection() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    invalidateAddressTest()
    snapshot.isLoading = true
    let custom = loadCustom
    let builtin = loadBuiltin
    let document = loadDocument
    let result = await Task.detached(priority: .userInitiated) {
      RulesCollection.load(custom: custom, builtin: builtin, document: document)
    }.value
    guard generation == refreshGeneration else { return }
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
      let commitDocument, let loadDocument
    else { return }
    let allowed = Set(snapshot.rows.filter { !$0.isFixed }.compactMap(\.identity))
    let targets = identities.intersection(allowed)
    guard !targets.isEmpty else { return }
    snapshot.isCommitting = true
    snapshot.commitOutcome = nil
    invalidateAddressTest()
    defer { snapshot.isCommitting = false }
    do {
      let old = try loadDocument()
      guard let prepared = collection?.userDocument,
        old.rules == prepared.rules && old.disabledIdentities == prepared.disabledIdentities
      else {
        snapshot.commitOutcome = .versionConflict
        await refreshCollection()
        return
      }
      var disabled = old.disabledIdentities
      if enabled { disabled.subtract(targets) } else { disabled.formUnion(targets) }
      guard disabled != old.disabledIdentities else { return }
      let outcome = await commitDocument(
        CustomRuleDocument(rules: old.rules, disabledIdentities: disabled))
      snapshot.commitOutcome = outcome
      await refreshCollection()
    } catch {
      snapshot.commitOutcome = .persistenceFailed
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
