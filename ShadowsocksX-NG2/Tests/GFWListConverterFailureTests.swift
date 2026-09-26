import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// GFWList 转换失败条件（issue #65）：未知语法、空输入、异常规模与 Base64。
final class GFWListConverterFailureTests: XCTestCase {
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

  // MARK: - 失败条件

  func testUnknownSyntaxBlocksUpdate() {
    XCTAssertThrowsError(
      try convert(
        """
        ||keep.example.com
        ???bogus-rule???
        """)
    ) { error in
      XCTAssertEqual(
        error as? GFWListConverter.ConversionError,
        .unknownSyntax("???bogus-rule???"))
    }
  }

  func testEmptyInputBlocksUpdate() {
    XCTAssertThrowsError(try convert("\n! only comments\n")) { error in
      XCTAssertEqual(error as? GFWListConverter.ConversionError, .emptyInput)
    }
  }

  func testAbnormalRuleCountBlocksUpdate() {
    let strict = converter(minimumRuleCount: 10, maximumRuleCount: 100)
    XCTAssertThrowsError(try convert("||only.example.com\n", converter: strict)) { error in
      XCTAssertEqual(error as? GFWListConverter.ConversionError, .abnormalRuleCount(1))
    }
  }

  func testAbnormalShrinkageBlocksUpdate() {
    XCTAssertThrowsError(try convert("||only.example.com\n", previousRuleCount: 100)) { error in
      XCTAssertEqual(
        error as? GFWListConverter.ConversionError,
        .abnormalScaleChange(found: 1, previous: 100))
    }
  }

  func testGrowthWithinScaleRatioIsAccepted() throws {
    let snapshot = try convert(
      """
      ||a.example.com
      ||b.example.com
      ||c.example.com
      """,
      previousRuleCount: 4)
    XCTAssertEqual(snapshot.rules.count, 3)
  }

  // MARK: - Base64 官方分发格式

  func testDecodesOfficialBase64AutoProxyPayload() throws {
    let plain = "[AutoProxy 0.2.9]\n||b64.example.com\n@@||direct.example.com\n"
    let encoded = Data(plain.utf8).base64EncodedString()
    let snapshot = try converter().convert(
      base64Document: encoded,
      provenance: .init(
        fetchedAt: fetchedAt,
        upstreamReference: "gfwlist/gfwlist@test",
        license: "LGPL-2.1",
        attribution: "test attribution"),
      previousRuleCount: nil)
    XCTAssertEqual(proxyHosts(snapshot), ["b64.example.com"])
    XCTAssertEqual(directHosts(snapshot), ["direct.example.com"])
  }

  func testCorruptBase64BlocksUpdate() {
    XCTAssertThrowsError(
      try converter().convert(
        base64Document: "not!!!valid@@@base64",
        provenance: .init(
          fetchedAt: fetchedAt,
          upstreamReference: "gfwlist/gfwlist@test",
          license: "LGPL-2.1",
          attribution: "test attribution"),
        previousRuleCount: nil)
    ) { error in
      XCTAssertEqual(error as? GFWListConverter.ConversionError, .corruptInput)
    }
  }
}
