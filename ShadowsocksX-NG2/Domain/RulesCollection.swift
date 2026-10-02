import Foundation

/// Browsing includes all shipped rules and saved custom entries without changing runtime sources.
struct RulesCollection: Sendable {
  let version: String
  let rows: [RulesRow]
  let sources: [RulesSourceSnapshot]
  let issues: [RulesPageSnapshot.Issue]
  let userDocument: CustomRuleDocument?
  fileprivate let builtinInput: RulesCollectionInput

  static func load(
    custom loadCustom: () throws -> [CustomRule],
    builtin loadBuiltin: (RulesSource) throws -> RuleSnapshot,
    document loadDocument: (() throws -> CustomRuleDocument)? = nil
  ) -> RulesCollection {
    var builtin = RulesCollectionInput()
    for source in [RulesSource.geolocationCN, .chinaIPv4, .gfwlist] {
      builtin.readBuiltin(source, using: loadBuiltin)
    }
    var input = builtin
    input.readCustom { try loadDocument?() ?? CustomRuleDocument(rules: loadCustom()) }
    return input.collection(builtinInput: builtin)
  }

  /// A single prospective row uses the same analysis as browsing without sorting
  /// or recomputing every saved row on each editor keystroke.
  func previewRow(identity: RuleIdentity, document: CustomRuleDocument) -> RulesRow? {
    var input = builtinInput
    input.readCustom { document }
    return input.previewRow(identity: identity)
  }

  func replacingUserDocument(_ document: CustomRuleDocument) -> RulesCollection {
    var input = builtinInput
    input.readCustom { document }
    return input.collection(builtinInput: builtinInput)
  }
}

private struct RulesCandidate: Sendable {
  let rule: ProxyRule
  let source: RulesSource
  let customID: UUID?
}

private struct RulesCollectionInput: Sendable {
  var userDocument: CustomRuleDocument?
  var disabled: Set<RuleIdentity> = []
  var entries: [RulesCandidate] = []
  var sources: [RulesSourceSnapshot] = []
  var issues: [RulesPageSnapshot.Issue] = []
  var metadataTokens: [String] = []

  mutating func readCustom(_ loadCustom: () throws -> CustomRuleDocument) {
    do {
      let document = try loadCustom()
      let custom = document.rules
      disabled = document.disabledIdentities
      userDocument = document
      let validation = CustomRuleValidator.hardValidation(custom: custom)
      guard validation.rejected.isEmpty else {
        throw CustomRuleStoreError.corrupt(detail: "Invalid custom rule collection")
      }
      entries += custom.map { RulesCandidate(rule: $0.proxyRule, source: .custom, customID: $0.id) }
      sources.insert(
        RulesSourceSnapshot(id: .custom, count: custom.count, metadata: nil, conversionReport: nil),
        at: 0)
    } catch {
      issues.insert(.userDocument(String(describing: error)), at: 0)
    }
  }

  mutating func readBuiltin(
    _ source: RulesSource, using loadBuiltin: (RulesSource) throws -> RuleSnapshot
  ) {
    do {
      let snapshot = try loadBuiltin(source)
      let expected: RuleSourceKind
      switch source {
      case .geolocationCN: expected = .geolocationCN
      case .chinaIPv4: expected = .chinaIPv4
      case .gfwlist: expected = .gfwlist
      case .custom, .fixed: expected = .custom
      }
      guard snapshot.metadata.source.kind == expected
      else { throw RuleSnapshotError.corrupt(detail: "Unexpected rule source") }
      let candidates = snapshot.rules
      entries += candidates.map { RulesCandidate(rule: $0, source: source, customID: nil) }
      sources.append(
        RulesSourceSnapshot(
          id: source, count: candidates.count,
          metadata: snapshot.metadata, conversionReport: snapshot.lossReport))
      // Metadata changes invalidate details even when rule content is unchanged.
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      metadataTokens.append(
        source.rawValue + ProxyACLDocument.digest(try encoder.encode(snapshot.metadata)))
      metadataTokens.append(
        ProxyACLDocument.digest(try encoder.encode(snapshot.lossReport)))
    } catch {
      issues.append(.builtin(source, String(describing: error)))
    }
  }

  private mutating func appendFixedPolicy() {
    let fixedMatches = RuleCoverage.fixedLocalMatches
    entries += fixedMatches.map {
      RulesCandidate(
        rule: ProxyRule(action: .direct, match: $0), source: .fixed,
        customID: nil)
    }
    sources.append(
      RulesSourceSnapshot(
        id: .fixed, count: fixedMatches.count + 1, metadata: nil, conversionReport: nil))
  }

  mutating func previewRow(identity: RuleIdentity) -> RulesRow? {
    appendFixedPolicy()
    let memberships = entries.filter { $0.rule.identity == identity }
    guard !memberships.isEmpty else { return nil }
    let overlapping = entries.compactMap { candidate -> ProxyRule? in
      let rule = candidate.rule
      guard !disabled.contains(rule.identity),
        RuleCoverage.intersects(rule.identity.match, identity.match),
        rule.action != .proxy
          || RuleCoverage.fixedLocalCoverage(of: rule.identity.match)?.extent != .full
      else { return nil }
      return rule
    }
    return row(identity: identity, entries: memberships, overlapping: overlapping)
  }

  mutating func collection(builtinInput: RulesCollectionInput) -> RulesCollection {
    appendFixedPolicy()
    let grouped = Dictionary(grouping: entries, by: { $0.rule.identity })
    let rules = grouped.values.compactMap { $0.first?.rule }
    // Completely fixed-protected proxy candidates remain browsable but cannot
    // cover or shadow another candidate in the effective collection.
    let effective = rules.filter {
      !disabled.contains($0.identity)
        && ($0.action != .proxy
          || RuleCoverage.fixedLocalCoverage(of: $0.identity.match)?.extent != .full)
    }
    let index = RulesOverlapIndex(rules: effective)
    var rows = grouped.map { identity, entries in
      row(identity: identity, entries: entries, overlapping: index.overlapping(identity.match))
    }
    for identity in disabled where grouped[identity] == nil {
      rows.append(
        RulesRow(
          id: .rule(identity), identity: identity,
          content: identity.match.browsingContent, sources: [], customIDs: [],
          relationships: [], fixedCoverage: nil, isEnabled: false))
    }
    rows.append(
      RulesRow(
        id: .noDotHostname, identity: nil, content: "^[^.]+$", sources: [.fixed], customIDs: [],
        relationships: [], fixedCoverage: nil))
    // Tuple fields are evaluated eagerly. Prepare reflection-based identity
    // tokens once per row instead of rebuilding them on every sort comparison.
    rows = rows.map { row in
      (row: row, key: (row.content, row.action.rawValue, row.identity?.contentToken ?? ""))
    }.sorted { $0.key < $1.key }.map(\.row)
    let tokens =
      rows.map { row in
        (row.identity?.contentToken ?? "fixed:no-dot") + "|"
          + row.sources.map(\.rawValue).sorted().joined(separator: ",")
          + "|" + String(row.isEnabled) + "|"
          + row.customIDs.map(\.uuidString).sorted().joined(separator: ",")
      } + metadataTokens.sorted() + issues.map { String(describing: $0) }
    return RulesCollection(
      version: String(ProxyACLDocument.digest(tokens.sorted().joined(separator: "\n")).prefix(16)),
      rows: rows, sources: sources, issues: issues, userDocument: userDocument,
      builtinInput: builtinInput)
  }
  private func row(
    identity: RuleIdentity, entries: [RulesCandidate], overlapping: [ProxyRule]
  ) -> RulesRow {
    let memberships = Set(entries.map { $0.source })
    let representative = entries[0].rule
    var relationships =
      memberships.contains(.fixed)
      ? [] : RuleAnalysis(rules: overlapping, subjects: [representative]).relationships
    let fixedCoverage =
      memberships.contains(.fixed) ? nil : RuleCoverage.fixedLocalCoverage(of: identity.match)
    if identity.action == .direct, let fixedCoverage {
      relationships = relationships.compactMap { relationship in
        guard relationship.kind == .shadowing else { return relationship }
        guard fixedCoverage.extent == .partial else { return nil }
        return RuleRelationship(
          rule: identity, kind: .shadowing, extent: .partial,
          covering: relationship.covering)
      }
    }
    return RulesRow(
      id: .rule(identity), identity: identity, content: identity.match.browsingContent,
      sources: memberships, customIDs: Set(entries.compactMap { $0.customID }),
      relationships: disabled.contains(identity) ? [] : relationships, fixedCoverage: fixedCoverage,
      isEnabled: memberships.contains(.fixed) || !disabled.contains(identity))
  }

}

extension RuleMatch {
  var browsingContent: String {
    switch self {
    case .domainExact(let value), .domainSuffix(let value), .ipv4CIDR(let value),
      .ipv6CIDR(let value):
      value
    }
  }
}
