import Foundation
import XCTest

@testable import ShadowsocksX_NG2

final class ProxyACLTests: XCTestCase {
  func testDirectACLUsesBypassAllAndFixedLocalSafetyRules() {
    let acl = ProxyACLDocument.direct(
      at: URL(fileURLWithPath: "/tmp/ssxng-test/sslocal-active.acl"))

    XCTAssertTrue(acl.isWellFormed)
    XCTAssertTrue(acl.content.hasPrefix("[bypass_all]\n[bypass_list]\n"))
    XCTAssertFalse(acl.content.contains("[proxy_list]"))
    XCTAssertTrue(acl.content.contains("127.0.0.0/8\n"))
    XCTAssertTrue(acl.content.contains("10.0.0.0/8\n"))
    XCTAssertTrue(acl.content.contains("172.16.0.0/12\n"))
    XCTAssertTrue(acl.content.contains("192.168.0.0/16\n"))
    XCTAssertTrue(acl.content.contains("169.254.0.0/16\n"))
    XCTAssertTrue(acl.content.contains("::1/128\n"))
    XCTAssertTrue(acl.content.contains("fe80::/10\n"))
    XCTAssertTrue(acl.content.contains("fc00::/7\n"))
    XCTAssertTrue(acl.content.contains("||localhost\n"))
    XCTAssertTrue(acl.content.contains("||local\n"))
    XCTAssertTrue(acl.content.contains("^[^.]+$\n"))
    XCTAssertFalse(acl.content.contains("100.64.0.0/10"))
  }

  /// 全局模式（issue #62）：只含固定本地绕过的最小 ACL；不混入中国列表、
  /// GFWList 或自定义规则。公网目标默认代理，本地目标固定直连。
  func testGlobalACLUsesProxyAllAndOnlyFixedLocalSafetyRules() {
    let acl = ProxyACLDocument.global(
      at: URL(fileURLWithPath: "/tmp/ssxng-test/sslocal-active.acl"))

    XCTAssertTrue(acl.isWellFormed)
    XCTAssertEqual(acl.summary, "global")
    XCTAssertTrue(acl.content.hasPrefix("[proxy_all]\n[bypass_list]\n"))
    XCTAssertFalse(acl.content.contains("[proxy_list]"))
    XCTAssertFalse(acl.content.contains("[bypass_all]"))
    XCTAssertTrue(acl.content.contains("127.0.0.0/8\n"))
    XCTAssertTrue(acl.content.contains("10.0.0.0/8\n"))
    XCTAssertTrue(acl.content.contains("172.16.0.0/12\n"))
    XCTAssertTrue(acl.content.contains("192.168.0.0/16\n"))
    XCTAssertTrue(acl.content.contains("169.254.0.0/16\n"))
    XCTAssertTrue(acl.content.contains("::1/128\n"))
    XCTAssertTrue(acl.content.contains("fe80::/10\n"))
    XCTAssertTrue(acl.content.contains("fc00::/7\n"))
    XCTAssertTrue(acl.content.contains("||localhost\n"))
    XCTAssertTrue(acl.content.contains("||local\n"))
    XCTAssertTrue(acl.content.contains("^[^.]+$\n"))
    XCTAssertFalse(acl.content.contains("100.64.0.0/10"), "不加入 CGNAT")
    // 仅固定本地绕过：不携带任何来源规则或用户规则痕迹。
    let rules = Array(acl.content.split(separator: "\n").map(String.init).dropFirst(2))
    XCTAssertEqual(
      rules, FixedLocalProxyRanges.aclBypassRules,
      "全局 ACL 的规则区应与固定本地绕过完全一致")
  }

  func testACLRejectsChangedDigestAndNonAbsolutePath() {
    let valid = ProxyACLDocument.direct(
      at: URL(fileURLWithPath: "/tmp/ssxng-test/sslocal-active.acl"))
    let badDigest = ProxyACLDocument(
      path: valid.path,
      summary: valid.summary,
      content: valid.content,
      sha256: String(repeating: "0", count: 64))
    let relativePath = ProxyACLDocument(
      path: "sslocal-active.acl",
      summary: valid.summary,
      content: valid.content,
      sha256: valid.sha256)

    XCTAssertFalse(badDigest.isWellFormed)
    XCTAssertFalse(relativePath.isWellFormed)
  }

  // MARK: - 规则模式（issue #63）

  /// 规则＋未匹配时代理：proxy_all + 固定本地绕过 + 中国域名直连候选。
  func testRuleProxyDefaultACLUsesProxyAllAndChinaDirectCandidates() throws {
    let source = RuleSourceIdentity(
      kind: .geolocationCN, upstreamVersion: "v1", label: "geolocation-cn")
    let rules = [
      ProxyRule(action: .direct, match: try RuleMatch(nationalDomainSuffix: "cn"), source: source),
      ProxyRule(action: .direct, match: try RuleMatch(domainSuffix: "qq.com"), source: source),
      ProxyRule(
        action: .direct, match: try RuleMatch(domainExact: "api.example.cn"), source: source),
    ]
    let acl = ProxyACLDocument.rule(
      at: URL(fileURLWithPath: "/tmp/ssxng-test/sslocal-active.acl"),
      defaultAction: .proxyWhenUnmatched,
      rules: rules)

    XCTAssertTrue(acl.isWellFormed)
    XCTAssertEqual(acl.summary, "rule-proxy-default")
    XCTAssertTrue(acl.content.hasPrefix("[proxy_all]\n[bypass_list]\n"))
    XCTAssertFalse(acl.content.contains("[bypass_all]"))
    XCTAssertFalse(acl.content.contains("[proxy_list]"))
    // 固定本地绕过仍在。
    XCTAssertTrue(acl.content.contains("127.0.0.0/8\n"))
    XCTAssertTrue(acl.content.contains("||localhost\n"))
    // 中国域名直连候选。
    XCTAssertTrue(acl.content.contains("||cn\n"))
    XCTAssertTrue(acl.content.contains("||qq.com\n"))
    XCTAssertTrue(acl.content.contains("|api.example.cn\n"))
    XCTAssertFalse(acl.content.contains("100.64.0.0/10"), "不加入 CGNAT")
  }

  /// 规则＋未匹配时直连（issue #65）：bypass_all + 固定本地 + GFWList 可生效
  /// 代理规则。两种默认动作不把全部内置来源无条件并集，因此不混入中国直连项。
  func testRuleDirectDefaultACLUsesBypassAllAndGFWListProxyCandidates() throws {
    let gfwSource = RuleSourceIdentity(
      kind: .gfwlist, upstreamVersion: "v1", label: "GFWList")
    let rules = [
      ProxyRule(
        action: .proxy, match: try RuleMatch(domainSuffix: "blocked.example"), source: gfwSource),
      ProxyRule(
        action: .proxy, match: try RuleMatch(domainSuffix: "also-blocked.example"),
        source: gfwSource),
      ProxyRule(
        action: .direct, match: try RuleMatch(domainSuffix: "unshadowed.example"), source: gfwSource
      ),
    ]
    let acl = ProxyACLDocument.rule(
      at: URL(fileURLWithPath: "/tmp/ssxng-test/sslocal-active.acl"),
      defaultAction: .directWhenUnmatched,
      rules: rules)

    XCTAssertTrue(acl.isWellFormed)
    XCTAssertEqual(acl.summary, "rule-direct-default")
    XCTAssertTrue(acl.content.hasPrefix("[bypass_all]\n[bypass_list]\n"))
    XCTAssertTrue(acl.content.contains("[proxy_list]\n||blocked.example\n"))
    XCTAssertTrue(acl.content.contains("||also-blocked.example\n"))
    XCTAssertTrue(acl.content.contains("||unshadowed.example\n"), "未遮蔽例外参与编译进 bypass_list")
    XCTAssertFalse(acl.content.contains("[proxy_all]"))
    // 不无条件并集中国来源。
    XCTAssertFalse(acl.content.contains("||cn\n"))
    // 固定本地绕过仍在。
    XCTAssertTrue(acl.content.contains("127.0.0.0/8\n"))
    XCTAssertTrue(acl.content.contains("||localhost\n"))
    // 未匹配目标走 bypass_all 默认直连。
    XCTAssertTrue(acl.content.hasPrefix("[bypass_all]"))
  }

  /// 规则＋未匹配时直连：IP 字面目标无可用规则命中时直连（无 IP 代理规则时
  /// proxy_list 只有域名项）。
  func testRuleDirectDefaultACLLeavesIPLiteralsUnmatchedDirect() throws {
    let gfwSource = RuleSourceIdentity(
      kind: .gfwlist, upstreamVersion: "v1", label: "GFWList")
    let rules = [
      ProxyRule(
        action: .proxy, match: try RuleMatch(domainSuffix: "blocked.example"), source: gfwSource)
    ]
    let acl = ProxyACLDocument.rule(
      at: URL(fileURLWithPath: "/tmp/ssxng-test/sslocal-active.acl"),
      defaultAction: .directWhenUnmatched,
      rules: rules)

    let proxySection =
      (acl.content.components(separatedBy: "[proxy_list]\n").last ?? "")
      .split(whereSeparator: \.isNewline).map(String.init)
    XCTAssertTrue(
      proxySection.allSatisfy { line in
        line.hasPrefix("||") || line.hasPrefix("|") || line.hasPrefix("^")
      },
      "GFWList 代理候选只含域名规则；IP 字面目标未命中即直连")
  }

  /// 规则＋未匹配时代理（issue #64）：proxy_all 同时含中国域名与 IPv4 CIDR
  /// 直连候选，固定本地绕过仍优先。
  func testRuleProxyDefaultACLIncludesChinaIPv4CIDRCandidates() throws {
    let domainSource = RuleSourceIdentity(
      kind: .geolocationCN, upstreamVersion: "v1", label: "geolocation-cn")
    let cidrSource = RuleSourceIdentity(
      kind: .chinaIPv4, upstreamVersion: "c1", label: "china-operator-ip")
    let rules = [
      ProxyRule(
        action: .direct, match: try RuleMatch(nationalDomainSuffix: "cn"), source: domainSource),
      ProxyRule(
        action: .direct, match: try RuleMatch(ipv4CIDR: "203.0.113.0/24"), source: cidrSource),
      ProxyRule(
        action: .direct, match: try RuleMatch(ipv4CIDR: "198.51.100.0/24"), source: cidrSource),
    ]
    let acl = ProxyACLDocument.rule(
      at: URL(fileURLWithPath: "/tmp/ssxng-test/sslocal-active.acl"),
      defaultAction: .proxyWhenUnmatched,
      rules: rules)

    XCTAssertTrue(acl.isWellFormed)
    XCTAssertTrue(acl.content.hasPrefix("[proxy_all]\n[bypass_list]\n"))
    XCTAssertTrue(acl.content.contains("||cn\n"), "中国域名直连候选")
    XCTAssertTrue(acl.content.contains("203.0.113.0/24\n"), "中国 IPv4 CIDR 直连候选")
    XCTAssertTrue(acl.content.contains("198.51.100.0/24\n"), "中国 IPv4 CIDR 直连候选")
    // 固定本地绕过仍排在中国候选之前（优先级）。
    let lines = acl.content.split(separator: "\n").map(String.init)
    let localIndex = lines.firstIndex(of: "127.0.0.0/8") ?? -1
    let cidrIndex = lines.firstIndex(of: "203.0.113.0/24") ?? -1
    XCTAssertTrue(localIndex >= 0 && cidrIndex > localIndex, "固定本地绕过应优先于中国 CIDR")
  }

  /// 冲突元数据不影响 ACL 行；同匹配只输出一行。
  func testRuleACLLineMapping() throws {
    let source = RuleSourceIdentity(kind: .custom, upstreamVersion: "v1", label: "custom")
    XCTAssertEqual(
      ProxyRule(action: .direct, match: try RuleMatch(domainSuffix: "example.com"), source: source)
        .aclLine,
      "||example.com")
    XCTAssertEqual(
      ProxyRule(action: .direct, match: try RuleMatch(domainExact: "a.example.com"), source: source)
        .aclLine,
      "|a.example.com")
    XCTAssertEqual(
      ProxyRule(action: .direct, match: try RuleMatch(ipv4CIDR: "203.0.113.0/24"), source: source)
        .aclLine,
      "203.0.113.0/24")
    XCTAssertEqual(
      ProxyRule(action: .direct, match: try RuleMatch(ipv6CIDR: "2001:db8::/32"), source: source)
        .aclLine,
      "2001:db8::/32")
  }
}
