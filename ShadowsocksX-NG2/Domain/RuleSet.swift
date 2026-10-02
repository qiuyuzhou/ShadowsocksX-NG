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
      // 去重按 (action, match)：来源不影响运行时等价。
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
