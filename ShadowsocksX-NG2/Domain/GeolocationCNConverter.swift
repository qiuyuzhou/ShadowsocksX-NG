import Foundation

// MARK: - typed 条目

/// geolocation-cn / domain-list-community 文本格式的 typed 条目。
enum GeolocationEntry: Equatable, Sendable {
  case include(name: String, attributes: [String])
  case domain(String, attributes: [String])
  case full(String, attributes: [String])
  case keyword(String, attributes: [String])
  case regexp(String, attributes: [String])
  /// 裸域名，按 domain 后缀语义处理。
  case bareDomain(String, attributes: [String])

  var attributes: [String] {
    switch self {
    case .include(_, let attributes),
      .domain(_, let attributes),
      .full(_, let attributes),
      .keyword(_, let attributes),
      .regexp(_, let attributes),
      .bareDomain(_, let attributes):
      return attributes
    }
  }
}

/// typed 条目解析器：`domain:` / `full:` / `keyword:` / `regexp:` / `include:`
/// 前缀、裸域名、`@attr` 属性与 `#` 注释。
enum GeolocationParser {
  /// 解析单个文档（不含 include 展开）。
  static func parseDocument(_ text: String) -> [GeolocationEntry] {
    var entries: [GeolocationEntry] = []
    for rawLine in text.split(whereSeparator: \.isNewline) {
      if let entry = parseLine(String(rawLine)) {
        entries.append(entry)
      }
    }
    return entries
  }

  /// typed 前缀 → 条目构造的对照表；裸域名（无前缀）按 bareDomain 处理。
  private static let typedPrefixes:
    [(prefix: String, make: (String, [String]) -> GeolocationEntry)] = [
      ("include:", { .include(name: $0, attributes: $1) }),
      ("domain:", { .domain($0, attributes: $1) }),
      ("full:", { .full($0, attributes: $1) }),
      ("keyword:", { .keyword($0, attributes: $1) }),
      ("regexp:", { .regexp($0, attributes: $1) }),
    ]

  /// 去掉整行 `#` 注释与行内 ` #` 注释并修剪空白；空行返回 nil。
  private static func codeLine(from rawLine: String) -> String? {
    guard !rawLine.hasPrefix("#") else { return nil }
    var line = rawLine
    if let hashIndex = line.firstIndex(of: "#") {
      // 行内注释前必须有空白，避免切断 `regexp:` 中的 `#`。
      if line[line.index(before: hashIndex)].isWhitespace {
        line = String(line[line.startIndex..<hashIndex])
      }
    }
    line = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return line.isEmpty ? nil : line
  }

  /// 剥离尾部 `@attr` 属性（可多个，空格分隔），返回剩余内容与属性列表。
  private static func extractingAttributes(from line: String) -> (
    content: String, attributes: [String]
  ) {
    var parts = line.split(separator: " ", omittingEmptySubsequences: true)
    var attributes: [String] = []
    while let last = parts.last, last.hasPrefix("@") {
      attributes.insert(String(last.dropFirst()), at: 0)
      parts.removeLast()
    }
    return (parts.joined(separator: " "), attributes)
  }

  static func parseLine(_ rawLine: String) -> GeolocationEntry? {
    guard let line = codeLine(from: rawLine) else { return nil }
    let (content, attributes) = extractingAttributes(from: line)
    guard !content.isEmpty else { return nil }
    for typed in Self.typedPrefixes {
      guard content.hasPrefix(typed.prefix) else { continue }
      let value = String(content.dropFirst(typed.prefix.count))
        .trimmingCharacters(in: .whitespacesAndNewlines)
      guard !value.isEmpty else { return nil }
      return typed.make(value, attributes)
    }
    return .bareDomain(content, attributes: attributes)
  }
}

// MARK: - 转换器

/// geolocation-cn 转换器（issue #63）：解析 typed 条目、按 Loyalsoldier
/// 语义过滤属性、展开 include、`.cn` 后缀吸收，输出规范化快照与损失报告。
/// 未知语法/损坏输入/异常规模失败并保留上一份有效快照。
struct GeolocationCNConverter {
  /// Loyalsoldier/domain-list-custom 从 `geolocation-cn` 去除的属性（@ads、@!cn）。
  static let droppedAttributes: Set<String> = ["ads", "!cn"]

  /// 转换异常规模阈值：规则数低于下限或高于上限视为产物异常。
  static let minimumRuleCount = 100
  static let maximumRuleCount = 200_000

  let source: RuleSourceIdentity
  /// 可注入规模阈值（测试夹具用）；生产使用默认值。
  let minimumRuleCount: Int
  let maximumRuleCount: Int

  init(
    source: RuleSourceIdentity,
    minimumRuleCount: Int = GeolocationCNConverter.minimumRuleCount,
    maximumRuleCount: Int = GeolocationCNConverter.maximumRuleCount
  ) {
    self.source = source
    self.minimumRuleCount = minimumRuleCount
    self.maximumRuleCount = maximumRuleCount
  }

  /// include 解析缝：按名字提供子列表文本；缺失视为损坏输入。
  typealias DocumentProvider = (_ name: String) throws -> String

  enum ConversionError: Error, Equatable, Sendable {
    case missingInclude(String)
    case emptyInput
    case abnormalRuleCount(Int)
    case invalidEntry(String)
  }

  /// 快照元数据中由人工输入提供、与具体输入文本无关的部分；
  /// `source` 与 `inputDigest` 由转换器自行补齐。
  struct Provenance: Sendable {
    let fetchedAt: Date
    let upstreamReference: String
    let license: String
    let attribution: String
  }

  func convert(
    document: String,
    provenance: Provenance,
    provider: DocumentProvider
  ) throws -> RuleSnapshot {
    var report = RuleConversionLossReport()
    let entries = try expand(
      document: document,
      provider: provider,
      report: &report,
      visited: [])

    var rules: [ProxyRule] = []
    for entry in entries {
      if let rule = convertEntry(entry, report: &report) {
        rules.append(rule)
      }
    }

    // 去重（按 action+match），再增加 `.cn` 后缀并吸收。
    rules = RuleSet(rules: rules).rules

    // 增加 `.cn` 后缀直连规则（若输入未提供），再吸收同动作独立 .cn 域名。
    if !rules.contains(where: { $0.match == .domainSuffix("cn") }) {
      let cnRule = ProxyRule(
        action: .direct,
        match: .domainSuffix("cn"),
        source: source,
        conflict: RuleConflictMetadata(
          originalEntry: "synthesized:.cn-suffix", notes: ["synthesized-cn-suffix"]))
      rules.insert(cnRule, at: 0)
      report.notes.append("synthesized-cn-suffix")
    }
    let absorption = RuleCNabsorption.absorb(rules: rules)
    report.convertedCount = absorption.rules.count
    report.absorbedCount = absorption.absorbed.count

    let ruleCount = absorption.rules.count
    guard ruleCount >= minimumRuleCount else {
      throw ConversionError.abnormalRuleCount(ruleCount)
    }
    guard ruleCount <= maximumRuleCount else {
      throw ConversionError.abnormalRuleCount(ruleCount)
    }

    let metadata = RuleSnapshotMetadata(
      source: source,
      upstreamReference: provenance.upstreamReference,
      inputDigest: ProxyACLDocument.digest(Data(document.utf8)),
      fetchedAt: provenance.fetchedAt,
      license: provenance.license,
      attribution: provenance.attribution)
    return RuleSnapshot(
      metadata: metadata,
      rules: absorption.rules,
      absorbed: absorption.absorbed,
      lossReport: report)
  }

  private func makeRule(match: RuleMatch, original: String) -> ProxyRule {
    ProxyRule(
      action: .direct,
      match: match,
      source: source,
      conflict: RuleConflictMetadata(originalEntry: original))
  }

  /// 单条 typed 条目 → 规则；跳过/拒绝计入损失报告。返回 nil 表示不产出规则。
  private func convertEntry(
    _ entry: GeolocationEntry, report: inout RuleConversionLossReport
  ) -> ProxyRule? {
    let attributes = Set(entry.attributes)
    if !attributes.isDisjoint(with: Self.droppedAttributes) {
      report.incrementSkipped("attributeFiltered")
      return nil
    }
    switch entry {
    case .include:
      return nil
    case .keyword:
      report.incrementSkipped("keyword")
      return nil
    case .regexp:
      report.incrementSkipped("regexp")
      return nil
    case .domain(let value, _):
      return domainRule(value, original: "domain:\(value)", report: &report)
    case .full(let value, _):
      return exactRule(value, original: "full:\(value)", report: &report)
    case .bareDomain(let value, _):
      // 裸域名按 domain 后缀语义；`cn` 作为国家后缀单独引入。
      if value.lowercased() == "cn" {
        return domainRule(value, original: value, report: &report, allowNationalCN: true)
      }
      return domainRule(value, original: value, report: &report)
    }
  }

  private func domainRule(
    _ value: String, original: String, report: inout RuleConversionLossReport,
    allowNationalCN: Bool = false
  ) -> ProxyRule? {
    do {
      let match: RuleMatch
      if allowNationalCN, value.lowercased() == "cn" {
        match = try RuleMatch(nationalDomainSuffix: "cn")
      } else {
        match = try RuleMatch(domainSuffix: value)
      }
      return makeRule(match: match, original: original)
    } catch {
      report.incrementRejected("invalidDomain")
      return nil
    }
  }

  private func exactRule(
    _ value: String, original: String, report: inout RuleConversionLossReport
  ) -> ProxyRule? {
    do {
      return makeRule(match: try RuleMatch(domainExact: value), original: original)
    } catch {
      report.incrementRejected("invalidDomain")
      return nil
    }
  }

  private func expand(
    document: String,
    provider: DocumentProvider,
    report: inout RuleConversionLossReport,
    visited: Set<String>
  ) throws -> [GeolocationEntry] {
    let entries = GeolocationParser.parseDocument(document)
    var result: [GeolocationEntry] = []
    for entry in entries {
      guard case .include(let name, let attributes) = entry else {
        result.append(entry)
        continue
      }
      guard !visited.contains(name) else {
        report.incrementSkipped("includeCycle")
        continue
      }
      let childText: String
      do {
        childText = try provider(name)
      } catch {
        throw ConversionError.missingInclude(name)
      }
      report.incrementSkipped("includeResolved")
      var nextVisited = visited
      nextVisited.insert(name)
      let childEntries = try expand(
        document: childText,
        provider: provider,
        report: &report,
        visited: nextVisited)
      // 属性向下继承（domain-list-community 语义）。
      for child in childEntries {
        result.append(inheriting(attributes: attributes, from: child))
      }
    }
    return result
  }

  private func inheriting(attributes: [String], from entry: GeolocationEntry) -> GeolocationEntry {
    guard !attributes.isEmpty else { return entry }
    let merged = attributes + entry.attributes
    switch entry {
    case .include(let name, _):
      return .include(name: name, attributes: merged)
    case .domain(let value, _):
      return .domain(value, attributes: merged)
    case .full(let value, _):
      return .full(value, attributes: merged)
    case .keyword(let value, _):
      return .keyword(value, attributes: merged)
    case .regexp(let value, _):
      return .regexp(value, attributes: merged)
    case .bareDomain(let value, _):
      return .bareDomain(value, attributes: merged)
    }
  }
}
