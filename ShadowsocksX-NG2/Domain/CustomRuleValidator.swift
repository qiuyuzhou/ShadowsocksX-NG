import Darwin
import Foundation

// MARK: - CIDR 解析

enum AddressFamily: Equatable, Sendable {
  case ipv4
  case ipv6
}

struct ParsedCIDR: Equatable, Sendable {
  let family: AddressFamily
  let bytes: [UInt8]
  let prefixLength: Int
}

// MARK: - 拒绝原因

/// 自定义规则被拒绝的原因（issue #66 AC2）：与固定本地范围冲突，或被原版
/// sslocal 域名代理 / IP 直连优先级遮蔽。每条附可解释说明。
enum CustomRuleRejection: Equatable, Sendable {
  /// 代理动作覆盖固定本地范围（回环/私有/链路本地/localhost/*.local/无点主机名）。
  /// 系统绕过列表始终高于用户规则，该规则不会按用户意图生效。
  case conflictsWithFixedLocalScope
  /// 域名直连规则被更宽（或同覆盖）的域名代理规则遮蔽：sslocal 域名匹配
  /// 时 proxy_list 优先于 bypass_list。
  case shadowedByDomainProxy
  /// IP 代理规则被更宽（或同覆盖）的 IP 直连规则遮蔽：sslocal IP 匹配时
  /// bypass_list 优先于 proxy_list。
  case shadowedByIPDirect
  /// 同动作+同匹配条件重复。
  case duplicate

  var label: String {
    switch self {
    case .conflictsWithFixedLocalScope:
      return "与固定本地范围冲突"
    case .shadowedByDomainProxy:
      return "被域名代理优先级遮蔽"
    case .shadowedByIPDirect:
      return "被 IP 直连优先级遮蔽"
    case .duplicate:
      return "重复规则"
    }
  }
}

/// 被拒绝的自定义规则及其可解释原因。
struct RejectedCustomRule: Equatable, Sendable {
  let rule: CustomRule
  let reason: CustomRuleRejection
  /// 可解释说明：覆盖/遮蔽方的匹配条件描述，不含无关来源内容。
  let explanation: String
}

/// 校验结果：可生效规则（折叠为运行时规则）与被拒绝项。
struct CustomRuleValidationResult: Equatable, Sendable {
  let accepted: [ProxyRule]
  let rejected: [RejectedCustomRule]
}

// MARK: - 覆盖判定

/// 匹配条件的覆盖/相交判定：用于固定本地冲突与 ACL 优先级遮蔽检查。
enum RuleCoverage {
  // MARK: 域名

  /// `covering` 的域名目标集合是否包含 `covered` 的域名目标集合。
  static func domainCovers(_ covering: RuleMatch, _ covered: RuleMatch) -> Bool {
    guard let coveringDomain = domainValue(covering), let coveredDomain = domainValue(covered)
    else { return false }
    let coveringIsSuffix = isDomainSuffix(covering)
    let coveredIsSuffix = isDomainSuffix(covered)
    switch (coveringIsSuffix, coveredIsSuffix) {
    case (true, _):
      // 后缀覆盖：目标域等于后缀，或是后缀的子域。
      return coveredDomain == coveringDomain
        || coveredDomain.hasSuffix("." + coveringDomain)
    case (false, true):
      // 精确规则无法覆盖后缀规则（后缀还含子域）。
      return false
    case (false, false):
      return coveredDomain == coveringDomain
    }
  }

  /// 域名目标集合是否相交（用于固定本地冲突）。
  static func domainIntersects(_ lhs: RuleMatch, _ rhs: RuleMatch) -> Bool {
    // 任一覆盖另一即相交；后缀 vs 后缀若互不覆盖也可能相交（如 a.b 与 b.c），
    // 但固定本地规则是 `local`/`localhost`/无点，与多标签后缀的相交只能经覆盖。
    domainCovers(lhs, rhs) || domainCovers(rhs, lhs)
  }

  /// 是否命中固定本地主机模式：`localhost`、`*.local`、无点主机名。
  static func matchesFixedLocalHost(_ match: RuleMatch) -> Bool {
    guard let domain = domainValue(match) else { return false }
    let isSuffix = isDomainSuffix(match)
    // 无点主机名（含 `local` 本身）。
    if !domain.contains(".") {
      return true
    }
    // `*.local` / `local` 后缀。
    if isSuffix {
      return domain == "local" || domain.hasSuffix(".local")
    }
    return domain == "localhost" || domain.hasSuffix(".local") || domain.hasSuffix(".localhost")
  }

  /// 代理动作的域名规则是否与固定本地主机范围冲突。
  static func domainConflictsWithFixedLocal(_ match: RuleMatch) -> Bool {
    // 固定本地 ACL 主机规则：||localhost、||local、^[^.]+$。
    let fixedLocalHostMatches: [RuleMatch] = [
      .domainSuffix("localhost"),
      .domainSuffix("local"),
    ]
    if matchesFixedLocalHost(match) { return true }
    for fixed in fixedLocalHostMatches where domainIntersects(match, fixed) {
      return true
    }
    return false
  }

  // MARK: IP

  /// `covering` 的 IP 目标集合是否包含 `covered` 的 IP 目标集合（同地址族）。
  static func ipCovers(_ covering: RuleMatch, _ covered: RuleMatch) -> Bool {
    guard let outer = parseCIDR(covering), let inner = parseCIDR(covered),
      outer.family == inner.family
    else { return false }
    return outer.prefixLength <= inner.prefixLength
      && networkContains(outer: outer, inner: inner)
  }

  /// IP 目标集合是否相交。
  static func ipIntersects(_ lhs: RuleMatch, _ rhs: RuleMatch) -> Bool {
    guard let left = parseCIDR(lhs), let right = parseCIDR(rhs), left.family == right.family
    else { return false }
    return networkContains(outer: left, inner: right) || networkContains(outer: right, inner: left)
  }

  /// 代理动作的 IP 规则是否与固定本地 IP 范围冲突。
  static func ipConflictsWithFixedLocal(_ match: RuleMatch) -> Bool {
    for range in FixedLocalProxyRanges.ipRanges {
      if let fixed = try? parseFixedLocalCIDR(range), ipIntersects(match, fixed) {
        return true
      }
    }
    return false
  }

  // MARK: 解析

  static func parseCIDR(_ match: RuleMatch) -> ParsedCIDR? {
    switch match {
    case .ipv4CIDR(let cidr):
      return parseCIDRString(cidr, family: .ipv4, maxPrefix: 32)
    case .ipv6CIDR(let cidr):
      return parseCIDRString(cidr, family: .ipv6, maxPrefix: 128)
    case .domainExact, .domainSuffix:
      return nil
    }
  }

  private static func parseFixedLocalCIDR(_ raw: String) -> RuleMatch? {
    if raw.contains(":") {
      return try? RuleMatch(ipv6CIDR: raw)
    }
    return try? RuleMatch(ipv4CIDR: raw)
  }

  private static func parseCIDRString(
    _ cidr: String, family: AddressFamily, maxPrefix: Int
  ) -> ParsedCIDR? {
    let parts = cidr.split(separator: "/", maxSplits: 1)
    guard !parts.isEmpty else { return nil }
    let addressPart = String(parts[0])
    let prefixLength: Int
    if parts.count == 2 {
      guard let parsed = Int(parts[1]), (0...maxPrefix).contains(parsed) else { return nil }
      prefixLength = parsed
    } else {
      prefixLength = maxPrefix
    }
    switch family {
    case .ipv4:
      var address = in_addr()
      guard addressPart.withCString({ inet_pton(AF_INET, $0, &address) }) == 1 else { return nil }
      let host = UInt32(bigEndian: address.s_addr)
      let mask: UInt32 = prefixLength == 0 ? 0 : UInt32.max << (32 - prefixLength)
      let network = host & mask
      let bytes = withUnsafeBytes(of: network.bigEndian) { Array($0) }
      return ParsedCIDR(family: .ipv4, bytes: bytes, prefixLength: prefixLength)
    case .ipv6:
      var address = in6_addr()
      guard addressPart.withCString({ inet_pton(AF_INET6, $0, &address) }) == 1 else { return nil }
      var bytes = withUnsafeBytes(of: address) { Array($0) }
      for index in 0..<16 {
        let bitStart = index * 8
        if prefixLength >= bitStart + 8 { continue }
        if prefixLength <= bitStart {
          bytes[index] = 0
        } else {
          let keep = prefixLength - bitStart
          bytes[index] &= UInt8.max << (8 - keep)
        }
      }
      return ParsedCIDR(family: .ipv6, bytes: bytes, prefixLength: prefixLength)
    }
  }

  private static func networkContains(outer: ParsedCIDR, inner: ParsedCIDR) -> Bool {
    let fullBytes = outer.prefixLength / 8
    let remainderBits = outer.prefixLength % 8
    guard outer.bytes.count == inner.bytes.count else { return false }
    for index in 0..<fullBytes where outer.bytes[index] != inner.bytes[index] {
      return false
    }
    if remainderBits > 0 {
      let mask = UInt8.max << (8 - remainderBits)
      guard (outer.bytes[fullBytes] & mask) == (inner.bytes[fullBytes] & mask) else {
        return false
      }
    }
    return true
  }

  private static func domainValue(_ match: RuleMatch) -> String? {
    switch match {
    case .domainExact(let domain), .domainSuffix(let domain):
      return domain
    case .ipv4CIDR, .ipv6CIDR:
      return nil
    }
  }

  private static func isDomainSuffix(_ match: RuleMatch) -> Bool {
    if case .domainSuffix = match { return true }
    return false
  }
}

// MARK: - 校验器

/// 自定义规则校验（issue #66 AC2）：拒绝与固定本地范围冲突、重复，以及
/// 被原版 sslocal 域名代理 / IP 直连优先级遮蔽的规则，并返回可解释原因。
///
/// 遮蔽判定相对「将进入同一 ACL 的规则集合」（内置来源 + 其他自定义规则）。
/// 固定本地冲突是模式无关的硬拒绝；遮蔽与 ACL 骨架有关，由调用方按默认动作
/// 提供对应上下文。不把无效规则标为生效。
enum CustomRuleValidator {
  /// 校验一组自定义规则（issue #66）。
  ///
  /// - Parameters:
  ///   - custom: 待校验的自定义规则（顺序保留）。
  ///   - builtIn: 将与自定义规则合并进同一 ACL 的内置规则。
  ///   - defaultAction: 规则模式子选项，决定 ACL 骨架与遮蔽语义。
  ///     「未匹配时代理」骨架不写 proxy_list（默认已是代理），代理动作规则
  ///     不会被域名代理优先级遮蔽（域名代理表为空），IP 代理也不参与
  ///     bypass 优先判定。
  static func validate(
    custom: [CustomRule],
    builtIn: [ProxyRule] = [],
    defaultAction: RuleDefaultAction
  ) -> CustomRuleValidationResult {
    let writesProxySide = defaultAction == .directWhenUnmatched

    var accepted: [ProxyRule] = []
    var rejected: [RejectedCustomRule] = []
    var seenTokens = Set<String>()
    // 遮蔽判定集合：先通过固定本地/重复检查的规则才可能进入 ACL，
    // 被拒绝的规则不得充当遮蔽方。
    var shadowContext = builtIn

    for rule in custom {
      let token = rule.contentToken
      if !seenTokens.insert(token).inserted {
        rejected.append(
          RejectedCustomRule(
            rule: rule,
            reason: .duplicate,
            explanation: "同动作同匹配条件的规则已存在"))
        continue
      }

      if let rejection = fixedLocalRejection(for: rule) {
        rejected.append(rejection)
        continue
      }

      if let rejection = shadowRejection(
        for: rule, in: shadowContext, writesProxySide: writesProxySide)
      {
        rejected.append(rejection)
        continue
      }

      accepted.append(rule.proxyRule)
      shadowContext.append(rule.proxyRule)
    }
    return CustomRuleValidationResult(accepted: accepted, rejected: rejected)
  }

  /// 单条规则的固定本地冲突检查（保存与编译共用）。
  static func fixedLocalRejection(for rule: CustomRule) -> RejectedCustomRule? {
    guard rule.action == .proxy else { return nil }
    let conflicts: Bool
    switch rule.match {
    case .domainExact, .domainSuffix:
      conflicts = RuleCoverage.domainConflictsWithFixedLocal(rule.match)
    case .ipv4CIDR, .ipv6CIDR:
      conflicts = RuleCoverage.ipConflictsWithFixedLocal(rule.match)
    }
    guard conflicts else { return nil }
    return RejectedCustomRule(
      rule: rule,
      reason: .conflictsWithFixedLocalScope,
      explanation: "系统绕过列表始终高于用户规则；代理固定本地目标不会生效")
  }

  /// ACL 优先级遮蔽检查：
  /// - 域名直连 vs 域名代理（proxy_list 优先）。
  /// - IP 代理 vs IP 直连（bypass_list 优先）。
  /// 仅在对应侧写入 ACL 时才可能被遮蔽。
  private static func shadowRejection(
    for rule: CustomRule,
    in merged: [ProxyRule],
    writesProxySide: Bool
  ) -> RejectedCustomRule? {
    switch rule.match {
    case .domainExact, .domainSuffix:
      // 域名直连被域名代理遮蔽；仅当代理侧写入 ACL 时才存在代理优先表。
      guard rule.action == .direct, writesProxySide else { return nil }
      for other in merged where other.action == .proxy {
        if RuleCoverage.domainCovers(other.match, rule.match) {
          return RejectedCustomRule(
            rule: rule,
            reason: .shadowedByDomainProxy,
            explanation: "域名代理规则 \(describe(other.match)) 优先于直连规则，本规则不会生效")
        }
      }
      return nil
    case .ipv4CIDR, .ipv6CIDR:
      // IP 代理被 IP 直连遮蔽；直连侧在两种骨架下都写入。
      guard rule.action == .proxy else { return nil }
      // 「未匹配时代理」不写 proxy_list，IP 代理规则不进入 ACL（默认已代理），
      // 不构成「被遮蔽」；只有写入 proxy 侧时才检查 IP 直连优先。
      guard writesProxySide else { return nil }
      for other in merged where other.action == .direct {
        if RuleCoverage.ipCovers(other.match, rule.match) {
          return RejectedCustomRule(
            rule: rule,
            reason: .shadowedByIPDirect,
            explanation: "IP 直连规则 \(describe(other.match)) 优先于代理规则，本规则不会生效")
        }
      }
      return nil
    }
  }

  private static func describe(_ match: RuleMatch) -> String {
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
