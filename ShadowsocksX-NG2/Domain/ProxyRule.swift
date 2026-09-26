import Darwin
import Foundation

// MARK: - 动作

/// 规则动作：目标经 Shadowsocks 代理，或直连。独立于 PAC、ACL 文本与
/// 系统代理设置（issue #63）。
enum RuleAction: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case proxy
  case direct
}

/// 规则模式的未匹配默认动作（issue #63）：未命中规则时走代理或直连。
/// 出厂默认「未匹配时代理」。
enum RuleDefaultAction: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case proxyWhenUnmatched = "proxy-when-unmatched"
  case directWhenUnmatched = "direct-when-unmatched"

  var label: String {
    switch self {
    case .proxyWhenUnmatched: "未匹配时代理"
    case .directWhenUnmatched: "未匹配时直连"
    }
  }

  /// 域名优先匹配下，未命中时的默认动作。
  var fallbackAction: RuleAction {
    switch self {
    case .proxyWhenUnmatched: .proxy
    case .directWhenUnmatched: .direct
    }
  }
}

// MARK: - 匹配条件

/// 规则匹配条件。完整域名、域名后缀与 IPv4/IPv6 CIDR 是可运行的统一类型；
/// 不把 URL 路径、协议、关键字或正则纳入（spec #59）。
enum RuleMatch: Equatable, Hashable, Codable, Sendable {
  private enum CodingKeys: String, CodingKey {
    case kind, value
  }

  private enum Kind: String, Codable {
    case domainExact, domainSuffix, ipv4CIDR, ipv6CIDR
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let value = try container.decode(String.self, forKey: .value)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .domainExact:
      self = .domainExact(value)
    case .domainSuffix:
      self = .domainSuffix(value)
    case .ipv4CIDR:
      self = .ipv4CIDR(value)
    case .ipv6CIDR:
      self = .ipv6CIDR(value)
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .domainExact(let value):
      try container.encode(Kind.domainExact, forKey: .kind)
      try container.encode(value, forKey: .value)
    case .domainSuffix(let value):
      try container.encode(Kind.domainSuffix, forKey: .kind)
      try container.encode(value, forKey: .value)
    case .ipv4CIDR(let value):
      try container.encode(Kind.ipv4CIDR, forKey: .kind)
      try container.encode(value, forKey: .value)
    case .ipv6CIDR(let value):
      try container.encode(Kind.ipv6CIDR, forKey: .kind)
      try container.encode(value, forKey: .value)
    }
  }

  /// 完整域名精确匹配（`full:`）。
  case domainExact(String)
  /// 域名后缀匹配：域名本身及其所有子域（`domain:` / 裸域名）。
  case domainSuffix(String)
  /// IPv4 CIDR（规范化后的 `a.b.c.d/len`）。
  case ipv4CIDR(String)
  /// IPv6 CIDR（规范化后的压缩形式）。
  case ipv6CIDR(String)

  init(domainExact raw: String) throws {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty else { throw RuleMatchError.emptyDomain }
    guard !value.hasPrefix("."), !value.hasPrefix("*") else {
      throw RuleMatchError.invalidDomain(raw)
    }
    guard !value.hasSuffix(".") else { throw RuleMatchError.invalidDomain(raw) }
    guard value.allSatisfy({ Self.isDomainLabelCharacter($0) || $0 == "." }) else {
      throw RuleMatchError.invalidDomain(raw)
    }
    self = .domainExact(value)
  }

  init(domainSuffix raw: String) throws {
    var value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    while value.hasPrefix(".") { value.removeFirst() }
    guard !value.isEmpty else { throw RuleMatchError.emptyDomain }
    guard !value.hasPrefix("*"), !value.hasSuffix(".") else {
      throw RuleMatchError.invalidDomain(raw)
    }
    guard value.allSatisfy({ Self.isDomainLabelCharacter($0) || $0 == "." }) else {
      throw RuleMatchError.invalidDomain(raw)
    }
    // 单标签后缀（如 `com`）过宽；`cn` 作为国家后缀由吸收流程单独引入并显式允许。
    let labels = value.split(separator: ".")
    guard labels.count >= 2 else { throw RuleMatchError.invalidDomain(raw) }
    self = .domainSuffix(value)
  }

  /// 允许 `cn` 作为显式引入的国家后缀。
  init(nationalDomainSuffix raw: String) throws {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard value == "cn" else {
      // 回退到普通后缀校验。
      try self.init(domainSuffix: raw)
      return
    }
    self = .domainSuffix(value)
  }

  init(ipv4CIDR raw: String) throws {
    let normalized = try Self.normalizeIPv4CIDR(raw)
    self = .ipv4CIDR(normalized)
  }

  init(ipv6CIDR raw: String) throws {
    let normalized = try Self.normalizeIPv6CIDR(raw)
    self = .ipv6CIDR(normalized)
  }

  private static func isDomainLabelCharacter(_ character: Character) -> Bool {
    character.isASCII && (character.isLetter || character.isNumber || character == "-")
  }

  private static func normalizeIPv4CIDR(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RuleMatchError.invalidCIDR(raw) }
    let parts = trimmed.split(separator: "/", maxSplits: 1)
    let addressPart = String(parts[0])
    let prefixLength: Int
    if parts.count == 2 {
      guard let parsed = Int(parts[1]), (0...32).contains(parsed) else {
        throw RuleMatchError.invalidCIDR(raw)
      }
      prefixLength = parsed
    } else {
      prefixLength = 32
    }
    var address = in_addr()
    let converted = addressPart.withCString { inet_pton(AF_INET, $0, &address) }
    guard converted == 1 else {
      // 确认不是 IPv6。
      var probe = in6_addr()
      if addressPart.withCString({ inet_pton(AF_INET6, $0, &probe) }) == 1 {
        throw RuleMatchError.invalidCIDR(raw)
      }
      throw RuleMatchError.invalidCIDR(raw)
    }
    let host = UInt32(bigEndian: address.s_addr)
    let mask: UInt32 = prefixLength == 0 ? 0 : UInt32.max << (32 - prefixLength)
    let network = host & mask
    var networkAddress = in_addr(s_addr: network.bigEndian)
    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
    guard inet_ntop(AF_INET, &networkAddress, &buffer, socklen_t(INET_ADDRSTRLEN)) != nil else {
      throw RuleMatchError.invalidCIDR(raw)
    }
    let dotted = String(cString: buffer)
    return "\(dotted)/\(prefixLength)"
  }

  private static func normalizeIPv6CIDR(_ raw: String) throws -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { throw RuleMatchError.invalidCIDR(raw) }
    let parts = trimmed.split(separator: "/", maxSplits: 1)
    let addressPart = String(parts[0])
    let prefixLength: Int
    if parts.count == 2 {
      guard let parsed = Int(parts[1]), (0...128).contains(parsed) else {
        throw RuleMatchError.invalidCIDR(raw)
      }
      prefixLength = parsed
    } else {
      prefixLength = 128
    }
    var address = in6_addr()
    let converted = addressPart.withCString { inet_pton(AF_INET6, $0, &address) }
    guard converted == 1 else {
      var probe = in_addr()
      if addressPart.withCString({ inet_pton(AF_INET, $0, &probe) }) == 1 {
        throw RuleMatchError.invalidCIDR(raw)
      }
      throw RuleMatchError.invalidCIDR(raw)
    }
    // 按 16-bit 组掩码到前缀长度。
    var bytes = withUnsafeBytes(of: address) { Array($0) }
    for index in 0..<16 {
      let bitStart = index * 8
      if prefixLength >= bitStart + 8 { continue }
      if prefixLength <= bitStart {
        bytes[index] = 0
      } else {
        let keep = prefixLength - bitStart
        let mask = UInt8.max << (8 - keep)
        bytes[index] &= mask
      }
    }
    var networkAddress = bytes.withUnsafeBytes { rawPointer in
      rawPointer.load(as: in6_addr.self)
    }
    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
    guard inet_ntop(AF_INET6, &networkAddress, &buffer, socklen_t(INET6_ADDRSTRLEN)) != nil else {
      throw RuleMatchError.invalidCIDR(raw)
    }
    return "\(String(cString: buffer))/\(prefixLength)"
  }
}

enum RuleMatchError: Error, Equatable, Sendable {
  case emptyDomain
  case invalidDomain(String)
  case invalidCIDR(String)
}

// MARK: - 来源身份

/// 内置规则来源身份（issue #63）。
enum RuleSourceKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
  case geolocationCN = "geolocation-cn"
  case chinaIPv4 = "china-ipv4"
  case gfwlist = "gfwlist"
  case custom = "custom"
}

/// 规则来源身份：固定来源类别 + 上游版本 + 展示标签。冲突说明与快照元数据
/// 共用此身份。
struct RuleSourceIdentity: Codable, Equatable, Hashable, Sendable {
  let kind: RuleSourceKind
  let upstreamVersion: String
  let label: String

  init(kind: RuleSourceKind, upstreamVersion: String, label: String) {
    self.kind = kind
    self.upstreamVersion = upstreamVersion
    self.label = label
  }

  var id: String { kind.rawValue }
}

// MARK: - 冲突元数据

/// 冲突/覆盖说明元数据：记录原始条目、被谁吸收以及审查笔记。用于转换损失
/// 与冲突解释，不参与运行时匹配。
struct RuleConflictMetadata: Codable, Equatable, Hashable, Sendable {
  /// 转换前的原始条目文本（审计用）。
  let originalEntry: String
  /// 被哪条更宽规则吸收（如 `.cn` 后缀）；未吸收为 nil。
  let absorbedBy: RuleMatch?
  /// 审查笔记（吸收、遮蔽、跳过原因等）。
  let notes: [String]

  init(
    originalEntry: String,
    absorbedBy: RuleMatch? = nil,
    notes: [String] = []
  ) {
    self.originalEntry = originalEntry
    self.absorbedBy = absorbedBy
    self.notes = notes
  }
}

// MARK: - 规则

/// 一条来源无关的代理规则。
struct ProxyRule: Codable, Equatable, Hashable, Sendable {
  let action: RuleAction
  let match: RuleMatch
  let source: RuleSourceIdentity
  let conflict: RuleConflictMetadata

  init(
    action: RuleAction,
    match: RuleMatch,
    source: RuleSourceIdentity,
    conflict: RuleConflictMetadata = RuleConflictMetadata(originalEntry: "")
  ) {
    self.action = action
    self.match = match
    self.source = source
    self.conflict = conflict
  }

  /// sslocal ACL 单行表示（ASCII）。域名后缀 `||host`、完整域名 `|host`、
  /// CIDR 原样写入。
  var aclLine: String {
    switch match {
    case .domainExact(let domain):
      return "|\(domain)"
    case .domainSuffix(let domain):
      return "||\(domain)"
    case .ipv4CIDR(let cidr), .ipv6CIDR(let cidr):
      return cidr
    }
  }
}

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
