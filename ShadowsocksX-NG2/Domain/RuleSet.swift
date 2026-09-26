import Foundation

// MARK: - 规则集合

/// 同匹配条件下出现相反动作时的冲突记录。
struct RuleConflict: Codable, Equatable, Hashable, Sendable {
  let match: RuleMatch
  let actions: [RuleAction]
}

/// 规范化规则集合：去重、保留跨动作冲突说明。
struct RuleSet: Codable, Equatable, Sendable {
  private(set) var rules: [ProxyRule]
  private(set) var conflicts: [RuleConflict]

  init(rules: [ProxyRule]) {
    var ordered: [ProxyRule] = []
    var seen = Set<String>()
    for rule in rules {
      // 去重按 (action, match)：冲突元数据不同不影响运行时等价。
      let token = "\(rule.action.rawValue)|\(String(describing: rule.match))"
      guard seen.insert(token).inserted else { continue }
      ordered.append(rule)
    }
    self.rules = ordered
    self.conflicts = Self.detectConflicts(ordered)
  }

  private static func detectConflicts(_ rules: [ProxyRule]) -> [RuleConflict] {
    var actionsByMatch: [RuleMatch: [RuleAction]] = [:]
    for rule in rules {
      actionsByMatch[rule.match, default: []].append(rule.action)
    }
    return actionsByMatch.compactMap { match, actions in
      let unique = Array(Set(actions)).sorted { $0.rawValue < $1.rawValue }
      guard unique.count > 1 else { return nil }
      return RuleConflict(match: match, actions: unique)
    }
    .sorted {
      String(describing: $0.match) < String(describing: $1.match)
    }
  }
}

// MARK: - .cn 后缀吸收

/// `.cn` 后缀直连规则吸收同动作的独立 `.cn` 域名条目（issue #63）。
/// 只有 `.domainSuffix("cn")` 能吸收；完整域名 `cn` 不吸收。不同动作不吸收。
enum RuleCNabsorption {
  struct Result {
    /// 吸收后仍生效的规则。
    let rules: [ProxyRule]
    /// 被吸收的规则（conflict.absorbedBy 指向 `.cn` 后缀）。
    let absorbed: [ProxyRule]
  }

  static func absorb(rules: [ProxyRule]) -> Result {
    let cnSuffix = RuleMatch.domainSuffix("cn")
    guard rules.contains(where: { $0.match == cnSuffix }) else {
      return Result(rules: rules, absorbed: [])
    }
    // 取 `.cn` 后缀规则的动作集合；只有同动作条目才被吸收。
    let cnActions = Set(rules.filter { $0.match == cnSuffix }.map(\.action))
    var kept: [ProxyRule] = []
    var absorbed: [ProxyRule] = []
    for rule in rules {
      if rule.match == cnSuffix {
        kept.append(rule)
        continue
      }
      guard cnActions.contains(rule.action), isCoveredCNDomain(rule.match) else {
        kept.append(rule)
        continue
      }
      var conflict = rule.conflict
      conflict = RuleConflictMetadata(
        originalEntry: conflict.originalEntry.isEmpty
          ? String(describing: rule.match) : conflict.originalEntry,
        absorbedBy: cnSuffix,
        notes: conflict.notes + ["absorbed-by-cn-suffix"])
      absorbed.append(
        ProxyRule(action: rule.action, match: rule.match, source: rule.source, conflict: conflict))
    }
    return Result(rules: kept, absorbed: absorbed)
  }

  private static func isCoveredCNDomain(_ match: RuleMatch) -> Bool {
    switch match {
    case .domainExact(let domain):
      return domain.hasSuffix(".cn")
    case .domainSuffix(let domain):
      return domain.hasSuffix(".cn") && domain != "cn"
    case .ipv4CIDR, .ipv6CIDR:
      return false
    }
  }
}
