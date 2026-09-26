import Foundation

// MARK: - AutoProxy 条目

/// GFWList / AutoProxy 0.2.9 单行规则的分类结果。
/// 只有可按目标域名无损表达的规则进入领域模型；已知不可表达形式按类计数。
enum AutoProxyEntry: Equatable, Sendable {
  case header
  case comment
  case blank
  /// `||host` / `||host^`：域名及其子域 → domainSuffix。
  case domainProxy(host: String, original: String)
  /// `@@||host` / `@@||host^`：例外（直连）→ domainSuffix。
  case domainException(host: String, original: String)
  /// `|http://...` 等 URL 锚点（含协议条件），不扩大为整域名。
  case urlPrefix(original: String, isException: Bool)
  /// `||host/path` 或 `@@||host/path`：URL 路径条件，不扩大为整域名。
  case urlPath(original: String, isException: Bool)
  /// `||host$option`：过滤选项条件。
  case filterOption(original: String, isException: Bool)
  /// 通配符模式（`*`）。
  case wildcard(original: String, isException: Bool)
  /// `/regex/`。
  case regexp(original: String, isException: Bool)
  /// 裸文本（AutoProxy 子串匹配），不是域名规则。
  case plainText(original: String, isException: Bool)
  /// `||x` 单标签域名前缀：AutoProxy 语义是前缀匹配，不等价于 domainSuffix。
  case singleLabelPrefix(original: String, isException: Bool)
  /// `||1.2.3.4` 等 IP 字面量域名规则：不是 CIDR，不得猜测成 IP 代理规则。
  case ipLiteral(original: String, isException: Bool)
}

/// AutoProxy 0.2.9 行解析器。未知语法抛错，阻止更新。
enum AutoProxyParser {
  static func parseLine(_ rawLine: String) throws -> AutoProxyEntry {
    let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
    if line.isEmpty { return .blank }
    if line.hasPrefix("!") { return .comment }
    if line.hasPrefix("[") && line.hasSuffix("]") { return .header }

    let isException = line.hasPrefix("@@")
    let pattern = isException ? String(line.dropFirst(2)) : line

    if pattern.hasPrefix("||") {
      return try parseDomainPattern(
        String(pattern.dropFirst(2)), original: line, isException: isException)
    }
    if pattern.hasPrefix("|") {
      // URL 锚点：`|http://...` 含协议条件，不能无损映射为域名/IP。
      return .urlPrefix(original: line, isException: isException)
    }
    if pattern.hasPrefix("/"), pattern.hasSuffix("/"), pattern.count >= 3 {
      return .regexp(original: line, isException: isException)
    }
    if pattern.contains("*") {
      return .wildcard(original: line, isException: isException)
    }
    if looksLikeIPLiteral(pattern) {
      return .ipLiteral(original: line, isException: isException)
    }
    if isPlainDomainish(pattern) {
      return .plainText(original: line, isException: isException)
    }
    throw GFWListConverter.ConversionError.unknownSyntax(line)
  }

  private static func parseDomainPattern(
    _ hostPart: String, original: String, isException: Bool
  ) throws -> AutoProxyEntry {
    // `||host/path`：路径条件（优先于通配符，便于损失分类）。
    if hostPart.contains("/") {
      return .urlPath(original: original, isException: isException)
    }
    if hostPart.contains("*") {
      return .wildcard(original: original, isException: isException)
    }
    if hostPart.contains("$") {
      return .filterOption(original: original, isException: isException)
    }
    // `||host^` 或 `||host^rest`：`^` 是分隔符锚点；仅允许结尾单个 `^`。
    var host = hostPart
    if host.hasSuffix("^") {
      host = String(host.dropLast())
      if host.contains("^") {
        throw GFWListConverter.ConversionError.unknownSyntax(original)
      }
    }
    if looksLikeIPLiteral(host) {
      return .ipLiteral(original: original, isException: isException)
    }
    // 单标签（如 `google`）是域名前缀匹配，不等价于 domainSuffix。
    if !host.contains(".") {
      return .singleLabelPrefix(original: original, isException: isException)
    }
    guard isValidDomainHost(host) else {
      throw GFWListConverter.ConversionError.unknownSyntax(original)
    }
    if isException {
      return .domainException(host: host.lowercased(), original: original)
    }
    return .domainProxy(host: host.lowercased(), original: original)
  }

  private static func isValidDomainHost(_ host: String) -> Bool {
    !host.isEmpty && !host.hasPrefix(".") && !host.hasSuffix(".")
      && host.allSatisfy { character in
        character.isASCII
          && (character.isLetter || character.isNumber || character == "-" || character == ".")
      }
  }

  private static func looksLikeIPLiteral(_ text: String) -> Bool {
    var address = in_addr()
    if text.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 { return true }
    var address6 = in6_addr()
    if text.withCString({ inet_pton(AF_INET6, $0, &address6) }) == 1 { return true }
    // `1.2.3.4` 形态（非法数字也按 IP 字面量意图处理，避免落成 plainText）。
    let parts = text.split(separator: ".")
    return parts.count == 4 && parts.allSatisfy { $0.allSatisfy(\.isNumber) }
  }

  private static func isPlainDomainish(_ text: String) -> Bool {
    text.contains(".")
      && text.allSatisfy { character in
        character.isASCII
          && (character.isLetter || character.isNumber || character == "-" || character == ".")
      }
  }
}

// MARK: - 转换器

/// GFWList 转换器（issue #65）：解析官方 Base64 AutoProxy 列表，只转换可按
/// 目标域名无损表达的规则；不把 URL 路径或协议条件扩大为整域名。被更宽代理
/// 规则遮蔽的 `@@` 例外不写入无效 ACL 项，保留代理规则并逐项报告。未知语法、
/// 损坏输入或异常缩小阻止更新；普通构建离线读取已固定快照。
struct GFWListConverter {
  /// 转换异常规模阈值。
  static let minimumRuleCount = 100
  static let maximumRuleCount = 50_000
  /// 相对上一份快照的规模漂移阈值（issue #65 异常缩小）。
  static let minimumScaleRatio = 0.5
  static let maximumScaleRatio = 2.0

  let source: RuleSourceIdentity
  let minimumRuleCount: Int
  let maximumRuleCount: Int

  init(
    source: RuleSourceIdentity,
    minimumRuleCount: Int = GFWListConverter.minimumRuleCount,
    maximumRuleCount: Int = GFWListConverter.maximumRuleCount
  ) {
    self.source = source
    self.minimumRuleCount = minimumRuleCount
    self.maximumRuleCount = maximumRuleCount
  }

  enum ConversionError: Error, Equatable, Sendable {
    case emptyInput
    case corruptInput
    case unknownSyntax(String)
    case abnormalRuleCount(Int)
    case abnormalScaleChange(found: Int, previous: Int)
  }

  /// 快照元数据中由人工输入提供、与具体输入文本无关的部分。
  struct Provenance: Sendable {
    let fetchedAt: Date
    let upstreamReference: String
    let license: String
    let attribution: String
  }

  /// 解码官方 Base64 分发物后再转换。
  func convert(
    base64Document: String,
    provenance: Provenance,
    previousRuleCount: Int? = nil
  ) throws -> RuleSnapshot {
    let compact = base64Document.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let decoded = Data(base64Encoded: compact, options: [.ignoreUnknownCharacters]),
      let document = String(data: decoded, encoding: .utf8)
    else {
      throw ConversionError.corruptInput
    }
    return try convert(
      document: document, provenance: provenance, previousRuleCount: previousRuleCount)
  }

  func convert(
    document: String,
    provenance: Provenance,
    previousRuleCount: Int? = nil
  ) throws -> RuleSnapshot {
    var report = RuleConversionLossReport()
    var proxyRules: [ProxyRule] = []
    var exceptionRules: [ProxyRule] = []
    var sawCodeLine = false

    for rawLine in document.split(
      omittingEmptySubsequences: false, whereSeparator: \.isNewline)
    {
      let entry = try AutoProxyParser.parseLine(String(rawLine))
      try accumulate(
        entry, proxyRules: &proxyRules, exceptionRules: &exceptionRules,
        sawCodeLine: &sawCodeLine, report: &report)
    }
    guard sawCodeLine else { throw ConversionError.emptyInput }

    // 被更宽（或同宽）代理规则遮蔽的 @@ 例外不写入无效 ACL 项。
    let shadowing = ShadowingAnalyzer.split(
      proxyRules: proxyRules, exceptionRules: exceptionRules)
    report.incrementSkipped("shadowedException", by: shadowing.shadowed.count)
    for (exception, shadowedBy) in shadowing.shadowed {
      report.notes.append(
        "shadowed-exception: \(exception.conflict.originalEntry) shadowed-by \(shadowedBy.conflict.originalEntry)"
      )
    }

    var rules = RuleSet(rules: shadowing.keptProxy + shadowing.keptExceptions).rules
    report.convertedCount = rules.count
    report.absorbedCount = shadowing.shadowed.count
    try validateRuleCount(rules.count, previousRuleCount: previousRuleCount)

    let metadata = RuleSnapshotMetadata(
      source: source,
      upstreamReference: provenance.upstreamReference,
      inputDigest: ProxyACLDocument.digest(Data(document.utf8)),
      fetchedAt: provenance.fetchedAt,
      license: provenance.license,
      attribution: provenance.attribution)
    return RuleSnapshot(
      metadata: metadata,
      rules: rules,
      absorbed: shadowing.shadowed.map(\.exception),
      lossReport: report)
  }

  /// 累计单条分类结果：可表达规则进列表，已知不可表达按类计数并报告。
  private func accumulate(
    _ entry: AutoProxyEntry,
    proxyRules: inout [ProxyRule],
    exceptionRules: inout [ProxyRule],
    sawCodeLine: inout Bool,
    report: inout RuleConversionLossReport
  ) throws {
    switch entry {
    case .blank:
      report.incrementSkipped("blank")
    case .comment:
      report.incrementSkipped("comment")
    case .header:
      report.incrementSkipped("header")
    case .domainProxy(let host, let original):
      sawCodeLine = true
      proxyRules.append(
        makeRule(action: .proxy, match: try RuleMatch(domainSuffix: host), original: original))
    case .domainException(let host, let original):
      sawCodeLine = true
      exceptionRules.append(
        makeRule(action: .direct, match: try RuleMatch(domainSuffix: host), original: original))
    case .urlPrefix, .urlPath, .filterOption, .wildcard, .regexp, .plainText,
      .singleLabelPrefix, .ipLiteral:
      sawCodeLine = true
      let label = unexpressibleLabel(for: entry)
      recordUnexpressible(
        label.category, note: label.note, original: label.original, report: &report)
    }
  }

  private struct UnexpressibleLabel {
    let category: String
    let note: String
    let original: String
  }

  private func unexpressibleLabel(for entry: AutoProxyEntry) -> UnexpressibleLabel {
    switch entry {
    case .urlPrefix(let original, _):
      return UnexpressibleLabel(category: "urlPrefix", note: "url-prefix", original: original)
    case .urlPath(let original, _):
      return UnexpressibleLabel(category: "urlPath", note: "url-path", original: original)
    case .filterOption(let original, _):
      return UnexpressibleLabel(category: "filterOption", note: "filter-option", original: original)
    case .wildcard(let original, _):
      return UnexpressibleLabel(category: "wildcard", note: "wildcard", original: original)
    case .regexp(let original, _):
      return UnexpressibleLabel(category: "regexp", note: "regexp", original: original)
    case .plainText(let original, _):
      return UnexpressibleLabel(category: "plainText", note: "plain-text", original: original)
    case .singleLabelPrefix(let original, _):
      return UnexpressibleLabel(
        category: "singleLabelPrefix", note: "single-label-prefix", original: original)
    case .ipLiteral(let original, _):
      return UnexpressibleLabel(category: "ipLiteral", note: "ip-literal", original: original)
    default:
      return UnexpressibleLabel(category: "", note: "", original: "")
    }
  }

  private func recordUnexpressible(
    _ category: String, note: String, original: String, report: inout RuleConversionLossReport
  ) {
    report.incrementSkipped(category)
    report.notes.append("unexpressible-\(note): \(original)")
  }

  private func makeRule(action: RuleAction, match: RuleMatch, original: String) -> ProxyRule {
    ProxyRule(
      action: action,
      match: match,
      source: source,
      conflict: RuleConflictMetadata(originalEntry: original))
  }

  private func validateRuleCount(_ ruleCount: Int, previousRuleCount: Int?) throws {
    guard ruleCount >= minimumRuleCount else {
      throw ConversionError.abnormalRuleCount(ruleCount)
    }
    guard ruleCount <= maximumRuleCount else {
      throw ConversionError.abnormalRuleCount(ruleCount)
    }
    try validateScale(ruleCount: ruleCount, previousRuleCount: previousRuleCount)
  }

  private func validateScale(ruleCount: Int, previousRuleCount: Int?) throws {
    guard let previous = previousRuleCount, previous > 0 else { return }
    let lower = Int(Double(previous) * Self.minimumScaleRatio)
    let upper = Int(Double(previous) * Self.maximumScaleRatio)
    guard ruleCount >= lower, ruleCount <= upper else {
      throw ConversionError.abnormalScaleChange(found: ruleCount, previous: previous)
    }
  }
}

// MARK: - 例外遮蔽

/// 域名优先下（proxy_list 先于 bypass_list），被更宽代理规则覆盖的 `@@` 例外
/// 写入 ACL 也不会生效。保留代理规则，例外逐项报告并不进入规则列表。
enum ShadowingAnalyzer {
  struct Result {
    let keptProxy: [ProxyRule]
    let keptExceptions: [ProxyRule]
    let shadowed: [(exception: ProxyRule, shadowedBy: ProxyRule)]
  }

  static func split(proxyRules: [ProxyRule], exceptionRules: [ProxyRule]) -> Result {
    var keptExceptions: [ProxyRule] = []
    var shadowed: [(ProxyRule, ProxyRule)] = []
    for exception in exceptionRules {
      if let blocker = proxyRules.first(where: { covers(proxy: $0, exception: exception) }) {
        let marked = ProxyRule(
          action: exception.action,
          match: exception.match,
          source: exception.source,
          conflict: RuleConflictMetadata(
            originalEntry: exception.conflict.originalEntry,
            absorbedBy: blocker.match,
            notes: exception.conflict.notes + ["shadowed-by-broader-proxy"]))
        shadowed.append((marked, blocker))
      } else {
        keptExceptions.append(exception)
      }
    }
    return Result(
      keptProxy: proxyRules, keptExceptions: keptExceptions,
      shadowed: shadowed.map { (exception: $0.0, shadowedBy: $0.1) })
  }

  /// 代理规则是否在域名匹配上覆盖例外（相等或更宽的后缀）。
  static func covers(proxy: ProxyRule, exception: ProxyRule) -> Bool {
    switch (proxy.match, exception.match) {
    case (.domainSuffix(let broad), .domainSuffix(let narrow)):
      return domainSuffixCovers(broad: broad, narrow: narrow)
    case (.domainSuffix(let broad), .domainExact(let narrow)):
      return domainSuffixCovers(broad: broad, narrow: narrow)
    case (.domainExact(let broad), .domainExact(let narrow)):
      return broad.lowercased() == narrow.lowercased()
    case (.domainExact(let broad), .domainSuffix(let narrow)):
      // 精确匹配只覆盖同名主机；后缀例外范围更宽，不被其遮蔽。
      return broad.lowercased() == narrow.lowercased()
    default:
      // IP 规则的优先级方向不同（bypass 先于 proxy），此处不按域名遮蔽处理。
      return false
    }
  }

  static func domainSuffixCovers(broad: String, narrow: String) -> Bool {
    let broadHost = broad.lowercased()
    let narrowHost = narrow.lowercased()
    return narrowHost == broadHost || narrowHost.hasSuffix("." + broadHost)
  }
}
