import Foundation

/// Session browsing state belongs to the workflow, so navigation never discards it.
struct RulesQuery: Equatable, Sendable {
  enum Sort: String, CaseIterable, Sendable { case ascending, descending }
  var search = ""
  var action: RuleAction?
  var source: RulesSource?
  var sort: Sort = .ascending
}

enum RulesSource: String, CaseIterable, Identifiable, Sendable {
  case custom, geolocationCN, chinaIPv4, gfwlist, fixed
  var id: Self { self }
}

struct RulesSourceSnapshot: Equatable, Identifiable, Sendable {
  let id: RulesSource
  let count: Int
  let metadata: RuleSnapshotMetadata?
  let conversionReport: RuleConversionLossReport?
}

struct RulesRow: Equatable, Identifiable, Sendable {
  enum SelectionID: Hashable, Sendable {
    case rule(RuleIdentity)
    case noDotHostname
  }
  let id: SelectionID
  let identity: RuleIdentity?
  let content: String
  let sources: Set<RulesSource>
  let customIDs: Set<UUID>
  let relationships: [RuleRelationship]
  let fixedCoverage: FixedRuleCoverage?
  var isFixed: Bool { sources.contains(.fixed) }
  var action: RuleAction { identity?.action ?? .direct }
}

struct RulesPageSnapshot: Equatable, Sendable {
  enum Issue: Equatable, Hashable, Sendable {
    case userDocument(String)
    case builtin(RulesSource, String)
  }
  var version = ""
  var isLoading = false
  var issues: [Issue] = []
  var sources: [RulesSourceSnapshot] = []
  var rows: [RulesRow] = []
  var selection: Set<RulesRow.SelectionID> = []
  var query = RulesQuery()
  var addressTest = RulesAddressTest()
  var isComplete: Bool { !isLoading && issues.isEmpty && !version.isEmpty }
}
