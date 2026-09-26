import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// 规则领域模型（issue #63）：动作、匹配条件、来源身份与冲突元数据独立于
/// PAC、ACL 文本和系统代理设置。
final class ProxyRuleTests: XCTestCase {
  // MARK: - 动作与匹配

  func testActionsAreProxyAndDirect() {
    XCTAssertEqual(RuleAction.allCases, [.proxy, .direct])
    XCTAssertEqual(RuleAction.proxy.rawValue, "proxy")
    XCTAssertEqual(RuleAction.direct.rawValue, "direct")
  }

  func testMatchKindsCoverDomainAndCIDR() throws {
    let exact = try RuleMatch(domainExact: "api.example.com")
    let suffix = try RuleMatch(domainSuffix: "example.com")
    let v4 = try RuleMatch(ipv4CIDR: "203.0.113.0/24")
    let v6 = try RuleMatch(ipv6CIDR: "2001:db8::/32")

    XCTAssertEqual(exact, .domainExact("api.example.com"))
    XCTAssertEqual(suffix, .domainSuffix("example.com"))
    XCTAssertEqual(v4, .ipv4CIDR("203.0.113.0/24"))
    XCTAssertEqual(v6, .ipv6CIDR("2001:db8::/32"))
  }

  func testDomainExactRejectsSuffixSemantics() {
    XCTAssertThrowsError(try RuleMatch(domainExact: "example.com."))
    XCTAssertThrowsError(try RuleMatch(domainExact: ".example.com"))
    XCTAssertThrowsError(try RuleMatch(domainExact: "*.example.com"))
    XCTAssertThrowsError(try RuleMatch(domainExact: ""))
    XCTAssertThrowsError(try RuleMatch(domainExact: "exa mple.com"))
    XCTAssertThrowsError(try RuleMatch(domainExact: "例子.com"))
  }

  func testDomainSuffixNormalizesAndRejectsInvalid() throws {
    XCTAssertEqual(try RuleMatch(domainSuffix: "Example.COM"), .domainSuffix("example.com"))
    XCTAssertEqual(try RuleMatch(domainSuffix: ".example.com"), .domainSuffix("example.com"))
    XCTAssertThrowsError(try RuleMatch(domainSuffix: "example.com."))
    XCTAssertThrowsError(try RuleMatch(domainSuffix: "*.example.com"))
    XCTAssertThrowsError(try RuleMatch(domainSuffix: ""))
    XCTAssertThrowsError(try RuleMatch(domainSuffix: "localhost"))
    XCTAssertThrowsError(try RuleMatch(domainSuffix: "com"), "单标签后缀不允许，避免过宽匹配")
  }

  func testIPv4CIDRNormalizesHostAddressesAndRejectsInvalid() throws {
    XCTAssertEqual(try RuleMatch(ipv4CIDR: "203.0.113.7"), .ipv4CIDR("203.0.113.7/32"))
    XCTAssertEqual(try RuleMatch(ipv4CIDR: "203.0.113.0/24"), .ipv4CIDR("203.0.113.0/24"))
    // 主机位非零的前缀按网络地址规范化。
    XCTAssertEqual(try RuleMatch(ipv4CIDR: "203.0.113.15/24"), .ipv4CIDR("203.0.113.0/24"))
    XCTAssertThrowsError(try RuleMatch(ipv4CIDR: "203.0.113.0/33"))
    XCTAssertThrowsError(try RuleMatch(ipv4CIDR: "203.0.113.256/24"))
    XCTAssertThrowsError(try RuleMatch(ipv4CIDR: "2001:db8::/32"), "IPv6 不得进入 IPv4 匹配")
    XCTAssertThrowsError(try RuleMatch(ipv4CIDR: "not-an-ip"))
  }

  func testIPv6CIDRNormalizesAndRejectsInvalid() throws {
    XCTAssertEqual(try RuleMatch(ipv6CIDR: "2001:db8::/32"), .ipv6CIDR("2001:db8::/32"))
    XCTAssertEqual(
      try RuleMatch(ipv6CIDR: "2001:DB8:0:0:0:0:0:0/32"), .ipv6CIDR("2001:db8::/32"))
    XCTAssertThrowsError(try RuleMatch(ipv6CIDR: "2001:db8::/129"))
    XCTAssertThrowsError(try RuleMatch(ipv6CIDR: "203.0.113.0/24"), "IPv4 不得进入 IPv6 匹配")
    XCTAssertThrowsError(try RuleMatch(ipv6CIDR: "gggg::/32"))
  }

  // MARK: - 来源身份

  func testSourceIdentityCapturesKindAndUpstream() {
    let source = RuleSourceIdentity(
      kind: .geolocationCN,
      upstreamVersion: "20260925234224",
      label: "geolocation-cn")
    XCTAssertEqual(source.kind, .geolocationCN)
    XCTAssertEqual(source.upstreamVersion, "20260925234224")
    XCTAssertEqual(source.id, "geolocation-cn")
  }

  func testSourceKindsCoverBuiltInAndCustom() {
    XCTAssertEqual(
      RuleSourceKind.allCases,
      [.geolocationCN, .chinaIPv4, .gfwlist, .custom])
  }

  // MARK: - 规则与冲突元数据

  func testRuleCarriesActionMatchSourceAndConflictMetadata() throws {
    let source = RuleSourceIdentity(kind: .geolocationCN, upstreamVersion: "v1", label: "geo-cn")
    let rule = ProxyRule(
      action: .direct,
      match: try RuleMatch(domainSuffix: "example.com"),
      source: source,
      conflict: RuleConflictMetadata(
        originalEntry: "domain:example.com",
        absorbedBy: nil,
        notes: []))

    XCTAssertEqual(rule.action, .direct)
    XCTAssertEqual(rule.match, .domainSuffix("example.com"))
    XCTAssertEqual(rule.source.kind, .geolocationCN)
    XCTAssertEqual(rule.conflict.originalEntry, "domain:example.com")
    XCTAssertNil(rule.conflict.absorbedBy)
    XCTAssertTrue(rule.conflict.notes.isEmpty)
  }

  func testConflictMetadataRecordsAbsorption() throws {
    let metadata = RuleConflictMetadata(
      originalEntry: "foo.cn",
      absorbedBy: .domainSuffix("cn"),
      notes: ["absorbed-by-cn-suffix"])
    XCTAssertEqual(metadata.absorbedBy, .domainSuffix("cn"))
    XCTAssertEqual(metadata.notes, ["absorbed-by-cn-suffix"])
  }

  // MARK: - 规则集合规范化

  func testRuleSetDeduplicatesIdenticalRules() throws {
    let source = RuleSourceIdentity(kind: .geolocationCN, upstreamVersion: "v1", label: "geo-cn")
    let first = ProxyRule(
      action: .direct, match: try RuleMatch(domainSuffix: "example.com"), source: source)
    let second = ProxyRule(
      action: .direct, match: try RuleMatch(domainSuffix: "example.com"), source: source)
    let set = RuleSet(rules: [first, second])
    XCTAssertEqual(set.rules.count, 1)
  }

  func testRuleSetRecordsCrossActionConflict() throws {
    let source = RuleSourceIdentity(kind: .geolocationCN, upstreamVersion: "v1", label: "geo-cn")
    let direct = ProxyRule(
      action: .direct, match: try RuleMatch(domainSuffix: "example.com"), source: source)
    let proxy = ProxyRule(
      action: .proxy, match: try RuleMatch(domainSuffix: "example.com"), source: source)
    let set = RuleSet(rules: [direct, proxy])
    XCTAssertEqual(set.rules.count, 2, "不同动作的同匹配条件保留双方，冲突由元数据说明")
    XCTAssertEqual(set.conflicts.count, 1)
    XCTAssertEqual(set.conflicts[0].match, .domainSuffix("example.com"))
    XCTAssertEqual(set.conflicts[0].actions, [.direct, .proxy])
  }

  // MARK: - .cn 后缀吸收

  func testCNSuffixAbsorbsSameActionIndependentCNDomains() throws {
    let source = RuleSourceIdentity(kind: .geolocationCN, upstreamVersion: "v1", label: "geo-cn")
    let cnSuffix = ProxyRule(
      action: .direct, match: try RuleMatch(nationalDomainSuffix: "cn"), source: source)
    let covered = ProxyRule(
      action: .direct, match: try RuleMatch(domainSuffix: "foo.cn"), source: source)
    let coveredExact = ProxyRule(
      action: .direct, match: try RuleMatch(domainExact: "bar.cn"), source: source)
    let otherAction = ProxyRule(
      action: .proxy, match: try RuleMatch(domainSuffix: "proxy.cn"), source: source)
    let unrelated = ProxyRule(
      action: .direct, match: try RuleMatch(domainSuffix: "example.com"), source: source)

    let absorbed = RuleCNabsorption.absorb(
      rules: [cnSuffix, covered, coveredExact, otherAction, unrelated])

    let matches = Set(absorbed.rules.map(\.match))
    XCTAssertTrue(matches.contains(.domainSuffix("cn")))
    XCTAssertTrue(matches.contains(.domainSuffix("example.com")))
    XCTAssertTrue(matches.contains(.domainSuffix("proxy.cn")), "不同动作不吸收")
    XCTAssertFalse(matches.contains(.domainSuffix("foo.cn")), "同动作 .cn 域名被吸收")
    XCTAssertFalse(matches.contains(.domainExact("bar.cn")), "同动作 .cn 完整域名被吸收")

    let absorbedEntries = absorbed.absorbed
    XCTAssertEqual(absorbedEntries.count, 2)
    XCTAssertTrue(absorbedEntries.allSatisfy { $0.conflict.absorbedBy == .domainSuffix("cn") })
  }

  func testCNExactDoesNotAbsorbAnything() throws {
    let source = RuleSourceIdentity(kind: .geolocationCN, upstreamVersion: "v1", label: "geo-cn")
    let cnExact = ProxyRule(
      action: .direct, match: try RuleMatch(domainExact: "cn"), source: source)
    let covered = ProxyRule(
      action: .direct, match: try RuleMatch(domainSuffix: "foo.cn"), source: source)
    let result = RuleCNabsorption.absorb(rules: [cnExact, covered])
    XCTAssertEqual(result.rules.count, 2, "只有 .cn 后缀才能吸收，完整域名 cn 不吸收")
  }
}
