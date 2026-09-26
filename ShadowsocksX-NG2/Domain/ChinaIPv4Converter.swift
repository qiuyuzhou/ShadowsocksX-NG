import Foundation

// MARK: - 转换器

/// china-operator-ip IPv4 CIDR 转换器（issue #64）：解析一行一个 CIDR 的文本、
/// 规范化并去重、输出规范化快照与损失报告。异常格式、全部失效或异常规模变化
/// 阻止替换快照；普通构建离线读取已固定快照。
struct ChinaIPv4Converter {
  /// 转换异常规模阈值：规则数低于下限或高于上限视为产物异常。
  static let minimumRuleCount = 100
  static let maximumRuleCount = 50_000

  /// 相对上一份快照的规模漂移阈值：新数量必须落在
  /// `[previous × minimumScaleRatio, previous × maximumScaleRatio]` 内。
  static let minimumScaleRatio = 0.5
  static let maximumScaleRatio = 2.0

  /// 异常格式阈值：拒绝行占代码行百分比超过该值即阻止替换（整数百分比）。
  static let maximumRejectionPercent = 5

  let source: RuleSourceIdentity
  /// 可注入规模阈值（测试夹具用）；生产使用默认值。
  let minimumRuleCount: Int
  let maximumRuleCount: Int
  let maximumRejectionPercent: Int

  init(
    source: RuleSourceIdentity,
    minimumRuleCount: Int = ChinaIPv4Converter.minimumRuleCount,
    maximumRuleCount: Int = ChinaIPv4Converter.maximumRuleCount,
    maximumRejectionPercent: Int = ChinaIPv4Converter.maximumRejectionPercent
  ) {
    self.source = source
    self.minimumRuleCount = minimumRuleCount
    self.maximumRuleCount = maximumRuleCount
    self.maximumRejectionPercent = maximumRejectionPercent
  }

  enum ConversionError: Error, Equatable, Sendable {
    case emptyInput
    case allEntriesInvalid
    case abnormalFormat(rejected: Int, total: Int)
    case abnormalRuleCount(Int)
    case abnormalScaleChange(found: Int, previous: Int)
  }

  /// 快照元数据中由人工输入提供、与具体输入文本无关的部分；
  /// `source` 与 `inputDigest` 由转换器自行补齐。
  struct Provenance: Sendable {
    let fetchedAt: Date
    let upstreamReference: String
    let license: String
    let attribution: String
  }

  /// `previousRuleCount`：上一份有效快照的规则数，用于异常规模变化检测。
  /// 首次建快照传 `nil` 时跳过漂移检查。
  func convert(
    document: String,
    provenance: Provenance,
    previousRuleCount: Int? = nil
  ) throws -> RuleSnapshot {
    let lines = document.split(whereSeparator: \.isNewline).map(String.init)
    guard lines.contains(where: { !Self.isIgnorableLine($0) }) else {
      throw ConversionError.emptyInput
    }

    var report = RuleConversionLossReport()
    let parsed = parseRules(from: lines, report: &report)
    guard parsed.rejectedCount == 0 || !parsed.rules.isEmpty else {
      throw ConversionError.allEntriesInvalid
    }
    // 异常格式：拒绝率超过阈值说明输入不是预期的 CIDR 文本，阻止替换快照。
    let codeLineCount =
      parsed.rules.count + parsed.rejectedCount + report.skipped["duplicate", default: 0]
    if codeLineCount > 0, parsed.rejectedCount * 100 > codeLineCount * maximumRejectionPercent {
      throw ConversionError.abnormalFormat(rejected: parsed.rejectedCount, total: codeLineCount)
    }
    try validateScale(
      ruleCount: parsed.rules.count, previousRuleCount: previousRuleCount)

    report.convertedCount = parsed.rules.count
    report.notes.append("china-ipv4-direct-candidates")

    let metadata = RuleSnapshotMetadata(
      source: source,
      upstreamReference: provenance.upstreamReference,
      inputDigest: ProxyACLDocument.digest(Data(document.utf8)),
      fetchedAt: provenance.fetchedAt,
      license: provenance.license,
      attribution: provenance.attribution)
    return RuleSnapshot(
      metadata: metadata,
      rules: parsed.rules,
      absorbed: [],
      lossReport: report)
  }

  private func parseRules(
    from lines: [String], report: inout RuleConversionLossReport
  ) -> (rules: [ProxyRule], rejectedCount: Int) {
    var rules: [ProxyRule] = []
    var seen = Set<RuleMatch>()
    var rejectedCount = 0
    for rawLine in lines {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !Self.isIgnorableLine(line) else { continue }
      do {
        let match = try RuleMatch(ipv4CIDR: line)
        // 去重按规范化后的 match；同一网络只保留一条。
        guard seen.insert(match).inserted else {
          report.incrementSkipped("duplicate")
          continue
        }
        rules.append(
          ProxyRule(
            action: .direct,
            match: match,
            source: source,
            conflict: RuleConflictMetadata(originalEntry: line)))
      } catch {
        rejectedCount += 1
        report.incrementRejected("invalidCIDR")
      }
    }
    return (rules, rejectedCount)
  }

  private func validateScale(ruleCount: Int, previousRuleCount: Int?) throws {
    guard ruleCount >= minimumRuleCount else {
      throw ConversionError.abnormalRuleCount(ruleCount)
    }
    guard ruleCount <= maximumRuleCount else {
      throw ConversionError.abnormalRuleCount(ruleCount)
    }
    guard let previous = previousRuleCount, previous > 0 else { return }
    let lower = Int(Double(previous) * Self.minimumScaleRatio)
    let upper = Int(Double(previous) * Self.maximumScaleRatio)
    guard ruleCount >= lower, ruleCount <= upper else {
      throw ConversionError.abnormalScaleChange(found: ruleCount, previous: previous)
    }
  }

  /// 空行与 `#` 注释行。
  private static func isIgnorableLine(_ line: String) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty || trimmed.hasPrefix("#")
  }
}
