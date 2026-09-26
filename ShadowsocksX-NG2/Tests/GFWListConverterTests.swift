import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// GFWList AutoProxy 转换器（issue #65）：Base64 解码、可表达域名规则、
/// 已知不可表达分类、`@@` 例外遮蔽、损失报告、来源元数据与异常缩小失败。
final class GFWListConverterTests: XCTestCase {
  private let source = RuleSourceIdentity(
    kind: .gfwlist,
    upstreamVersion: "test-version",
    label: "GFWList")

  private let fetchedAt = Date(timeIntervalSince1970: 1_764_000_000)

  private func converter(
    minimumRuleCount: Int = 1,
    maximumRuleCount: Int = 10_000
  ) -> GFWListConverter {
    GFWListConverter(
      source: source,
      minimumRuleCount: minimumRuleCount,
      maximumRuleCount: maximumRuleCount)
  }

  private func convert(
    _ document: String,
    previousRuleCount: Int? = nil,
    converter: GFWListConverter? = nil
  ) throws -> RuleSnapshot {
    try (converter ?? self.converter()).convert(
      document: document,
      provenance: .init(
        fetchedAt: fetchedAt,
        upstreamReference: "gfwlist/gfwlist@test",
        license: "LGPL-2.1",
        attribution: "test attribution"),
      previousRuleCount: previousRuleCount)
  }

  private func proxyHosts(_ snapshot: RuleSnapshot) -> [String] {
    snapshot.rules.compactMap { rule in
      guard rule.action == .proxy else { return nil }
      if case .domainSuffix(let value) = rule.match { return value }
      return nil
    }
  }

  private func directHosts(_ snapshot: RuleSnapshot) -> [String] {
    snapshot.rules.compactMap { rule in
      guard rule.action == .direct else { return nil }
      if case .domainSuffix(let value) = rule.match { return value }
      return nil
    }
  }

  // MARK: - 可表达域名规则

  func testConvertsDomainSuffixProxyRules() throws {
    let snapshot = try convert(
      """
      [AutoProxy 0.2.9]
      ! comment
      ||example.com
      ||sub.example.org^
      ||Foo.Bar.COM
      """)
    XCTAssertEqual(
      Set(proxyHosts(snapshot)),
      ["example.com", "sub.example.org", "foo.bar.com"])
    XCTAssertTrue(directHosts(snapshot).isEmpty)
    XCTAssertEqual(snapshot.lossReport.convertedCount, 3)
    XCTAssertTrue(snapshot.rules.allSatisfy { $0.action == .proxy })
    XCTAssertEqual(snapshot.metadata.source.kind, .gfwlist)
    XCTAssertEqual(snapshot.metadata.converterVersion, RuleSnapshotMetadata.currentConverterVersion)
    XCTAssertFalse(snapshot.metadata.inputDigest.isEmpty)
    XCTAssertFalse(snapshot.metadata.license.isEmpty)
    XCTAssertFalse(snapshot.metadata.attribution.isEmpty)
    XCTAssertEqual(snapshot.metadata.fetchedAt, fetchedAt)
  }

  func testCaretAndBareDomainFormsShareDomainSuffixSemantics() throws {
    let snapshot = try convert(
      """
      ||example.com
      ||example.com^
      ||www.example.com
      """)
    // 去重后 example.com 只保留一条。
    XCTAssertEqual(proxyHosts(snapshot), ["example.com", "www.example.com"])
  }

  // MARK: - 已知不可表达：不扩大为整域名

  func testDoesNotExpandURLPathOrProtocolConditions() throws {
    // 夹具只含不可表达条目；把下限调 0 以便只验证分类与不扩大。
    let snapshot = try convert(
      """
      |http://news.example.com/path
      |https://secure.example.org
      ||path.example.net/foo/bar
      ||path.example.net/*-*/deep
      ||option.example.edu$third-party
      ||cdn*.example.io
      /regex-rule/
      plain-substring.example
      ||keep.example.com
      """,
      converter: converter(minimumRuleCount: 0))
    XCTAssertEqual(proxyHosts(snapshot), ["keep.example.com"])
    XCTAssertEqual(snapshot.lossReport.skipped["urlPrefix"], 2)
    XCTAssertEqual(snapshot.lossReport.skipped["urlPath"], 2)
    XCTAssertEqual(snapshot.lossReport.skipped["filterOption"], 1)
    XCTAssertEqual(snapshot.lossReport.skipped["wildcard"], 1)
    XCTAssertEqual(snapshot.lossReport.skipped["regexp"], 1)
    XCTAssertEqual(snapshot.lossReport.skipped["plainText"], 1)
    XCTAssertEqual(snapshot.lossReport.rejected, [:])
  }

  func testClassifiesHeaderCommentsAndBlanksWithoutFailing() throws {
    let snapshot = try convert(
      """
      [AutoProxy 0.2.9]
      ! Title: GFWList

      ||keep.example.com
      """)
    XCTAssertEqual(proxyHosts(snapshot), ["keep.example.com"])
    XCTAssertNil(snapshot.lossReport.skipped["unknownSyntax"])
    XCTAssertEqual(snapshot.lossReport.skipped["header"], 1)
    XCTAssertEqual(snapshot.lossReport.skipped["comment"], 1)
    XCTAssertGreaterThanOrEqual(snapshot.lossReport.skipped["blank"] ?? 0, 1)
  }

  func testSingleLabelDomainPrefixIsNotLossless() throws {
    // `||google` 在 AutoProxy 是域名前缀匹配，不等价于 domainSuffix("google")。
    let snapshot = try convert(
      """
      ||google
      ||goog
      ||gle
      ||google.com
      """)
    XCTAssertEqual(proxyHosts(snapshot), ["google.com"])
    XCTAssertEqual(snapshot.lossReport.skipped["singleLabelPrefix"], 3)
  }

  func testRejectsIPLiteralDomainStyleRulesAsNotCIDR() throws {
    // `||1.2.3.4` 是主机名字面量域名规则，不是 CIDR；不得猜测成 IP 代理规则。
    let snapshot = try convert(
      """
      ||1.2.3.4
      |http://8.8.8.8/
      ||valid.example.com
      """)
    XCTAssertEqual(proxyHosts(snapshot), ["valid.example.com"])
    XCTAssertEqual(snapshot.lossReport.skipped["ipLiteral"], 1)
    XCTAssertEqual(snapshot.lossReport.skipped["urlPrefix"], 1)
  }

  // MARK: - @@ 例外与遮蔽

  func testUnshadowedExceptionBecomesDirectRule() throws {
    let snapshot = try convert(
      """
      ||blocked.example
      @@||other.example
      """)
    XCTAssertEqual(proxyHosts(snapshot), ["blocked.example"])
    XCTAssertEqual(directHosts(snapshot), ["other.example"])
    XCTAssertEqual(snapshot.lossReport.skipped["shadowedException"] ?? 0, 0)
  }

  func testExceptionShadowedByBroaderProxyIsNotWritten() throws {
    let snapshot = try convert(
      """
      ||example.com
      ||gstatic.com
      @@||fonts.gstatic.com
      @@||www.example.com
      @@||unrelated.example.org
      """)
    // 遮蔽的例外不写入无效 ACL 项；更宽代理规则保留。
    XCTAssertEqual(Set(proxyHosts(snapshot)), ["example.com", "gstatic.com"])
    XCTAssertEqual(directHosts(snapshot), ["unrelated.example.org"])
    XCTAssertEqual(snapshot.lossReport.skipped["shadowedException"], 2)
    XCTAssertEqual(snapshot.lossReport.absorbedCount, 2, "遮蔽例外计入吸收/遮蔽条目数")
    let notes = snapshot.lossReport.notes.joined(separator: "\n")
    XCTAssertTrue(notes.contains("@@||fonts.gstatic.com"), "逐项报告被遮蔽的例外")
    XCTAssertTrue(notes.contains("@@||www.example.com"))
    XCTAssertTrue(notes.contains("||gstatic.com") || notes.contains("||example.com"))
    // 被遮蔽例外保留在 absorbed 供审计。
    XCTAssertEqual(snapshot.absorbed.count, 2)
    XCTAssertTrue(
      snapshot.absorbed.allSatisfy {
        $0.action == .direct && $0.conflict.notes.contains("shadowed-by-broader-proxy")
      })
  }

  func testEqualMatchExceptionIsShadowedByProxy() throws {
    let snapshot = try convert(
      """
      ||same.example
      @@||same.example
      """)
    XCTAssertEqual(proxyHosts(snapshot), ["same.example"])
    XCTAssertTrue(directHosts(snapshot).isEmpty)
    XCTAssertEqual(snapshot.lossReport.skipped["shadowedException"], 1)
  }

  func testNarrowerProxyDoesNotShadowBroaderException() throws {
    // 更窄代理规则不遮蔽更宽例外：两者都保留；sslocal 域名优先级由 proxy_list 先匹配。
    let snapshot = try convert(
      """
      ||sub.example.com
      @@||example.com
      """)
    XCTAssertEqual(proxyHosts(snapshot), ["sub.example.com"])
    XCTAssertEqual(directHosts(snapshot), ["example.com"])
    XCTAssertEqual(snapshot.lossReport.skipped["shadowedException"] ?? 0, 0)
  }

  func testExceptionComplexFormsAreClassifiedNotShadowed() throws {
    let snapshot = try convert(
      """
      ||example.com
      @@||*.tokenplus.app
      @@|https://cdn.example.net/path
      @@/regex-exception/
      """)
    XCTAssertEqual(proxyHosts(snapshot), ["example.com"])
    XCTAssertTrue(directHosts(snapshot).isEmpty)
    XCTAssertEqual(snapshot.lossReport.skipped["wildcard"], 1)
    XCTAssertEqual(snapshot.lossReport.skipped["urlPrefix"], 1)
    XCTAssertEqual(snapshot.lossReport.skipped["regexp"], 1)
  }
}
