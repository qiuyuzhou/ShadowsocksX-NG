import Foundation

/// Coverage is explanatory, never a persistence rejection or a routing priority.
struct RuleRelationship: Equatable, Sendable {
  enum Kind: Hashable, Sendable { case absorption, shadowing }
  enum Extent: Sendable { case full, partial }
  let rule: RuleIdentity
  let kind: Kind
  let extent: Extent
  let covering: [RuleIdentity]
}

/// Analyze the complete candidate set. Optional subjects limit explanation work
/// to custom entries at the existing validation seam without narrowing context.
struct RuleAnalysis: Equatable, Sendable {
  let identities: [RuleIdentity]
  let relationships: [RuleRelationship]

  var contentVersion: String {
    String(
      ProxyACLDocument.digest(identities.map(\.contentToken).joined(separator: "\n")).prefix(12))
  }

  init(rules: [ProxyRule], subjects: [ProxyRule]? = nil) {
    let identities = Array(Set(rules.map(\.identity))).sorted {
      $0.contentToken < $1.contentToken
    }
    self.identities = identities
    let targets = Set((subjects ?? rules).map(\.identity))
    relationships = identities.filter { targets.contains($0) }.flatMap { target in
      [RuleRelationship.Kind.absorption, .shadowing].compactMap { kind in
        let covering = identities.filter { other in
          guard other != target else { return false }
          switch kind {
          case .absorption:
            guard other.action == target.action else { return false }
          case .shadowing:
            guard other.action != target.action,
              RuleCoverage.winningAction(for: target.match) == other.action
            else { return false }
          }
          return RuleCoverage.intersects(other.match, target.match)
        }
        guard !covering.isEmpty else { return nil }
        return RuleRelationship(
          rule: target, kind: kind,
          extent: RuleCoverage.fullyCovered(target.match, by: covering.map(\.match))
            ? .full : .partial,
          covering: covering)
      }
    }
  }
}

/// Fixed policy includes a semantic simple-hostname condition, not an editable
/// regex identity. Coverage keeps that condition separate from ordinary rules.
struct FixedRuleCoverage: Equatable, Sendable {
  let extent: RuleRelationship.Extent
  let matches: [RuleMatch]
  let includesSimpleHostname: Bool
}

extension RuleCoverage {
  static let fixedLocalMatches: [RuleMatch] = {
    FixedLocalProxyRanges.ipRanges.compactMap { value in
      value.contains(":") ? try? RuleMatch(ipv6CIDR: value) : try? RuleMatch(ipv4CIDR: value)
    } + [.domainSuffix("localhost"), .domainSuffix("local")]
  }()

  static func fixedLocalCoverage(of match: RuleMatch) -> FixedRuleCoverage? {
    let matches = fixedLocalMatches.filter { intersects($0, match) }
    let simple: Bool
    let simpleIsFull: Bool
    switch match {
    case .domainExact(let value):
      simple = !value.contains(".")
      simpleIsFull = simple
    case .domainSuffix(let value):
      simple = !value.contains(".")
      simpleIsFull = false
    case .ipv4CIDR, .ipv6CIDR:
      simple = false
      simpleIsFull = false
    }
    guard simple || !matches.isEmpty else { return nil }
    return FixedRuleCoverage(
      extent: simpleIsFull || fullyCovered(match, by: matches) ? .full : .partial,
      matches: matches, includesSimpleHostname: simple)
  }
}
