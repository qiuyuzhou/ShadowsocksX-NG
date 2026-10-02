import XCTest

@testable import ShadowsocksX_NG2

final class RuleAnalysisTests: XCTestCase {
  func testDomainShadowingSeparatesFullCoverageFromPartialOverlap() {
    let broad = CustomRule(action: .direct, match: .domainSuffix("example.com"))
    let narrow = CustomRule(action: .proxy, match: .domainExact("a.example.com"))
    let partial = RuleAnalysis(rules: [broad.proxyRule, narrow.proxyRule])
    XCTAssertEqual(
      partial.relationships,
      [
        RuleRelationship(
          rule: broad.identity, kind: .shadowing, extent: .partial,
          covering: [narrow.identity])
      ])
    let full = RuleAnalysis(rules: [
      broad.proxyRule,
      CustomRule(action: .proxy, match: .domainSuffix("example.com")).proxyRule,
    ])
    XCTAssertEqual(full.relationships.first?.extent, .full)
  }
  func testIdentityNormalizesContentWithoutUsingCustomUUIDOrMergingFamilies() {
    let host = CustomRule(action: .proxy, match: .ipv4CIDR("203.0.113.8"))
    let cidr = CustomRule(action: .proxy, match: .ipv4CIDR("203.0.113.8/32"))
    XCTAssertNotEqual(host.id, cidr.id)
    XCTAssertEqual(host.identity, cidr.identity)
    XCTAssertEqual(host.contentToken, cidr.contentToken)
    XCTAssertNotEqual(
      host.identity,
      CustomRule(action: .direct, match: host.match).identity)
    XCTAssertNotEqual(
      host.identity,
      CustomRule(action: .proxy, match: .ipv6CIDR("::ffff:203.0.113.8/128")).identity)
    XCTAssertEqual(
      CustomRule(action: .direct, match: .domainSuffix(".Example.COM")).identity.match,
      .domainSuffix("example.com"))
  }

  func testAnalysisAndVersionsDoNotDependOnDuplicateRulesOrCustomOrder() {
    let custom = [
      CustomRule(action: .direct, match: .domainSuffix("example.com")),
      CustomRule(action: .direct, match: .domainExact("a.example.com")),
      CustomRule(action: .proxy, match: .domainExact("a.example.com")),
    ]
    let builtIn = [ProxyRule(action: .proxy, match: .domainSuffix("a.example.com"))]
    let expected = RuleAnalysis(rules: builtIn + custom.map(\.proxyRule))
    for order in [custom, Array(custom.reversed()), [custom[1], custom[2], custom[0]]] {
      for sourceOrder in [builtIn, builtIn + builtIn] {
        let actual = RuleAnalysis(rules: order.map(\.proxyRule) + sourceOrder)
        XCTAssertEqual(actual, expected)
        XCTAssertEqual(actual.contentVersion, expected.contentVersion)
        XCTAssertEqual(CustomRuleSummary.summarizing(order), CustomRuleSummary.summarizing(custom))
        for action in RuleDefaultAction.allCases {
          XCTAssertEqual(
            CustomRuleValidator.validate(
              custom: order, builtIn: sourceOrder, defaultAction: action),
            CustomRuleValidator.validate(custom: custom, builtIn: builtIn, defaultAction: action))
        }
      }
    }
    XCTAssertTrue(expected.relationships.contains { $0.kind == .absorption && $0.extent == .full })
    XCTAssertTrue(
      expected.relationships.contains { $0.kind == .shadowing && $0.extent == .partial })
  }

  func testIPCoverageCombinesNarrowerRangesAndKeepsPartialRemainder() {
    let broad = CustomRule(action: .proxy, match: .ipv4CIDR("203.0.113.0/24"))
    let lower = CustomRule(action: .direct, match: .ipv4CIDR("203.0.113.0/25"))
    let upper = CustomRule(action: .direct, match: .ipv6CIDR("::ffff:203.0.113.128/121"))
    XCTAssertEqual(
      RuleAnalysis(rules: [broad.proxyRule, lower.proxyRule])
        .relationships.first?.extent, .partial)
    let full = RuleAnalysis(rules: [upper.proxyRule, broad.proxyRule, lower.proxyRule])
    XCTAssertEqual(full.relationships.first?.extent, .full)
    XCTAssertEqual(full.relationships.first?.covering.count, 2)
  }

  func testSuffixBoundaryAndMappedCoverageFollowSslocal() {
    XCTAssertFalse(
      RuleCoverage.domainIntersects(
        .domainSuffix("example.com"), .domainExact("notexample.com")))
    XCTAssertFalse(
      RuleCoverage.domainCovers(
        .domainExact("example.com"), .domainExact("a.example.com")))
    XCTAssertTrue(
      RuleCoverage.ipCovers(
        .ipv4CIDR("203.0.113.0/24"), .ipv6CIDR("::ffff:203.0.113.8/128")))
    XCTAssertTrue(
      RuleCoverage.ipCovers(
        .ipv6CIDR("::ffff:203.0.113.0/120"), .ipv4CIDR("203.0.113.8/32")))
    XCTAssertFalse(
      RuleCoverage.ipIntersects(
        .ipv4CIDR("203.0.113.0/24"), .ipv6CIDR("2001:db8::/32")))
  }

}
