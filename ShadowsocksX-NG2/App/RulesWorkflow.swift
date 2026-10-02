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
  private var collection: RulesCollection?
  private var refreshGeneration = 0

  init(
    loadCustom: @escaping @Sendable () throws -> [CustomRule] = { try CustomRuleStore().load() },
    loadBuiltin: @escaping @Sendable (RulesSource) throws -> RuleSnapshot = { source in
      switch source {
      case .geolocationCN: try BuiltinRuleCatalog.loadGeolocationCN()
      case .chinaIPv4: try BuiltinRuleCatalog.loadChinaIPv4()
      case .gfwlist: try BuiltinRuleCatalog.loadGFWList()
      case .custom, .fixed: throw RuleSnapshotError.missing
      }
    }
  ) {
    self.loadCustom = loadCustom
    self.loadBuiltin = loadBuiltin
  }

  func refresh() async {
    refreshGeneration += 1
    let generation = refreshGeneration
    snapshot.isLoading = true
    let custom = loadCustom
    let builtin = loadBuiltin
    let result = await Task.detached(priority: .userInitiated) {
      RulesCollection.load(custom: custom, builtin: builtin)
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
        && (search.isEmpty || row.content.lowercased().contains(search))
    }
    if query.sort == .descending { rows.reverse() }
    var next = page
    next.rows = rows
    next.selection.formIntersection(Set(rows.map(\.id)))
    return next
  }
}
