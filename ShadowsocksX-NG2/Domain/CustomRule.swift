import Foundation

// MARK: - 自定义规则

/// 自定义规则（issue #66）：动作 + 匹配条件 + 来源元数据 + 稳定身份。
/// 为后续管理 UI 提供持久入口；本票不实现完整编辑、排序和删除界面。
/// 有效的完整域名、后缀及 CIDR 规则参与两种规则子模式的 ACL 合并。
struct CustomRule: Codable, Equatable, Hashable, Sendable, Identifiable {
  let id: UUID
  let action: RuleAction
  let match: RuleMatch
  /// 来源元数据：kind 恒为 `custom`，upstreamVersion/label 供冲突说明与展示。
  let source: RuleSourceIdentity

  init(
    id: UUID = UUID(),
    action: RuleAction,
    match: RuleMatch,
    source: RuleSourceIdentity? = nil
  ) {
    self.id = id
    self.action = action
    self.match = match
    self.source =
      source
      ?? RuleSourceIdentity(kind: .custom, upstreamVersion: "user", label: "自定义")
  }

  /// 折叠为来源无关的运行时规则，参与 ACL 合并。
  var proxyRule: ProxyRule {
    ProxyRule(action: action, match: match, source: source)
  }

  /// 稳定的内容身份（不含 UUID），用于去重与诊断摘要。
  var contentToken: String {
    "\(action.rawValue)|\(String(describing: match))"
  }
}

// MARK: - 持久化集合

/// 自定义规则持久化文档（issue #66）：schema 版本 + 规则数组。
struct CustomRuleDocument: Codable, Equatable, Sendable {
  static let currentSchemaVersion = 1

  let schemaVersion: Int
  let rules: [CustomRule]

  init(rules: [CustomRule]) {
    self.schemaVersion = Self.currentSchemaVersion
    self.rules = rules
  }
}

enum CustomRuleStoreError: Error, Equatable, Sendable {
  case missing
  case corrupt(detail: String)
  case schemaVersionMismatch(found: Int, expected: Int)
  case ioFailure(detail: String)
}

// MARK: - 诊断摘要

/// 自定义规则的安全诊断摘要（issue #66 AC5）：只含数量与内容版本，
/// 不导出原始自定义域名或来源内容。
struct CustomRuleSummary: Equatable, Sendable {
  /// 规则条数。
  let count: Int
  /// 内容版本：规则内容（动作+匹配）的稳定短摘要。
  let contentVersion: String

  static func summarizing(_ rules: [CustomRule]) -> CustomRuleSummary {
    CustomRuleSummary(count: rules.count, contentVersion: contentVersion(of: rules))
  }

  /// 内容版本按 (action, match) 排序后摘要；不含 UUID，重排不改版本。
  static func contentVersion(of rules: [CustomRule]) -> String {
    let payload =
      rules
      .map(\.contentToken)
      .sorted()
      .joined(separator: "\n")
    return String(ProxyACLDocument.digest(payload).prefix(12))
  }
}
