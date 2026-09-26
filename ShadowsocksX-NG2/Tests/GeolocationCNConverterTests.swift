import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// geolocation-cn 转换器（issue #63）：typed 条目、属性过滤、include 展开、
/// `.cn` 吸收、损失报告、来源元数据与异常规模失败。
final class GeolocationCNConverterTests: XCTestCase {
  private let source = RuleSourceIdentity(
    kind: .geolocationCN,
    upstreamVersion: "test-version",
    label: "geolocation-cn")

  private var converter: GeolocationCNConverter {
    GeolocationCNConverter(source: source, minimumRuleCount: 1, maximumRuleCount: 10_000)
  }

  private let fetchedAt = Date(timeIntervalSince1970: 1_764_000_000)

  private func convert(
    _ document: String,
    provider: @escaping GeolocationCNConverter.DocumentProvider = { _ in
      throw GeolocationCNConverter.ConversionError.missingInclude("?")
    }
  ) throws -> RuleSnapshot {
    try converter.convert(
      document: document,
      provenance: .init(
        fetchedAt: fetchedAt,
        upstreamReference: "test://upstream@v1",
        license: "MIT",
        attribution: "test attribution"),
      provider: provider)
  }

  // MARK: - typed 条目

  func testParsesTypedDomainFullAndBareEntries() throws {
    let snapshot = try convert(
      """
      # comment
      domain:example.com
      full:api.example.org
      bare-example.net
      keyword:skipme
      regexp:skipme-too
      """)
    let matches = snapshot.rules.map(\.match)
    XCTAssertTrue(matches.contains(.domainSuffix("example.com")))
    XCTAssertTrue(matches.contains(.domainExact("api.example.org")))
    XCTAssertTrue(matches.contains(.domainSuffix("bare-example.net")))
    XCTAssertFalse(
      matches.contains(where: {
        if case .domainSuffix(let value) = $0 { return value.contains("skipme") }
        return false
      }), "keyword/regexp 不进入规则模型")
    XCTAssertEqual(snapshot.lossReport.skipped["keyword"], 1)
    XCTAssertEqual(snapshot.lossReport.skipped["regexp"], 1)
    XCTAssertEqual(snapshot.lossReport.convertedCount, 4, "含合成 .cn 后缀")
  }

  func testDropsLoyalsoldierAttributeFilteredEntries() throws {
    let snapshot = try convert(
      """
      keep-me.com
      drop-ads.com @ads
      drop-notcn.com @!cn
      keep-attr.com @cn
      include:child @ads
      """,
      provider: { name in
        if name == "child" { return "child-kept.com\nchild-dropped.com @ads\n" }
        throw GeolocationCNConverter.ConversionError.missingInclude(name)
      })
    let values = snapshot.rules.compactMap { rule -> String? in
      switch rule.match {
      case .domainSuffix(let value): return value
      case .domainExact(let value): return value
      default: return nil
      }
    }
    XCTAssertTrue(values.contains("keep-me.com"))
    XCTAssertTrue(values.contains("keep-attr.com"))
    // include @ads 整支丢弃（属性向下继承）。
    XCTAssertFalse(values.contains("child-kept.com"))
    XCTAssertFalse(values.contains("child-dropped.com"))
    XCTAssertFalse(values.contains("drop-ads.com"))
    XCTAssertFalse(values.contains("drop-notcn.com"))
    XCTAssertEqual(snapshot.lossReport.skipped["attributeFiltered"], 4, "2 条目 + include 整支 2 子条目")
  }

  func testResolvesIncludesAndInheritsAttributes() throws {
    let snapshot = try convert(
      """
      include:child @ads
      include:clean
      top.com
      """,
      provider: { name in
        switch name {
        case "child": return "child.com\n"
        case "clean": return "clean.com\nfull:exact.clean.com\n"
        default: throw GeolocationCNConverter.ConversionError.missingInclude(name)
        }
      })
    let values = snapshot.rules.map(\.match)
    XCTAssertTrue(values.contains(.domainSuffix("top.com")))
    XCTAssertTrue(values.contains(.domainSuffix("clean.com")))
    XCTAssertTrue(values.contains(.domainExact("exact.clean.com")))
    XCTAssertFalse(values.contains(.domainSuffix("child.com")), "include @ads 整支过滤")
    XCTAssertEqual(snapshot.lossReport.skipped["includeResolved"], 2)
  }

  func testMissingIncludeFailsConversion() {
    XCTAssertThrowsError(
      try convert(
        "include:missing\nexample.com\n",
        provider: { name in
          throw GeolocationCNConverter.ConversionError.missingInclude(name)
        })
    ) { error in
      XCTAssertEqual(
        error as? GeolocationCNConverter.ConversionError, .missingInclude("missing"))
    }
  }

  func testIncludeCycleIsSkippedNotFatal() throws {
    let snapshot = try convert(
      """
      include:a
      solo.com
      """,
      provider: { name in
        switch name {
        case "a": return "include:b\na.com\n"
        case "b": return "include:a\nb.com\n"
        default: throw GeolocationCNConverter.ConversionError.missingInclude(name)
        }
      })
    XCTAssertTrue(snapshot.rules.map(\.match).contains(.domainSuffix("solo.com")))
    XCTAssertEqual(snapshot.lossReport.skipped["includeCycle"], 1)
  }

  // MARK: - .cn 吸收

  func testSynthesizesCNSuffixAndAbsorbsCoveredDomains() throws {
    let snapshot = try convert(
      """
      foo.cn
      bar.com.cn
      full:exact.cn
      other.com
      proxy.cn @cn
      """)
    let matches = Set(snapshot.rules.map(\.match))
    XCTAssertTrue(matches.contains(.domainSuffix("cn")))
    XCTAssertTrue(matches.contains(.domainSuffix("other.com")))
    // 同动作 .cn 条目全部被吸收（含 @cn 属性条目，属性不影响吸收）。
    XCTAssertFalse(matches.contains(.domainSuffix("foo.cn")))
    XCTAssertFalse(matches.contains(.domainSuffix("bar.com.cn")))
    XCTAssertFalse(matches.contains(.domainExact("exact.cn")))
    XCTAssertFalse(matches.contains(.domainSuffix("proxy.cn")))
    XCTAssertEqual(snapshot.lossReport.absorbedCount, 4)
    XCTAssertTrue(
      snapshot.absorbed.allSatisfy { $0.conflict.absorbedBy == .domainSuffix("cn") })
    XCTAssertTrue(
      snapshot.lossReport.notes.contains("synthesized-cn-suffix"))
  }

  func testDoesNotDuplicateCNSuffixWhenInputProvidesIt() throws {
    let snapshot = try convert("cn\nfoo.cn\nexample.com\n")
    let cnRules = snapshot.rules.filter { $0.match == .domainSuffix("cn") }
    XCTAssertEqual(cnRules.count, 1)
    XCTAssertFalse(snapshot.lossReport.notes.contains("synthesized-cn-suffix"))
  }

  // MARK: - 去重与冲突

  func testDeduplicatesIdenticalEntries() throws {
    let snapshot = try convert("example.com\nexample.com\ndomain:example.com\n")
    let exampleRules = snapshot.rules.filter { $0.match == .domainSuffix("example.com") }
    XCTAssertEqual(exampleRules.count, 1)
  }

  // MARK: - 元数据与可复现输出

  func testSnapshotCarriesSourceMetadata() throws {
    let snapshot = try convert("example.com\n")
    XCTAssertEqual(snapshot.metadata.source.kind, .geolocationCN)
    XCTAssertEqual(snapshot.metadata.source.upstreamVersion, "test-version")
    XCTAssertEqual(snapshot.metadata.upstreamReference, "test://upstream@v1")
    XCTAssertEqual(snapshot.metadata.license, "MIT")
    XCTAssertEqual(snapshot.metadata.attribution, "test attribution")
    XCTAssertEqual(snapshot.metadata.fetchedAt, fetchedAt)
    XCTAssertEqual(
      snapshot.metadata.converterVersion, RuleSnapshotMetadata.currentConverterVersion)
    XCTAssertEqual(snapshot.schemaVersion, RuleSnapshot.currentSchemaVersion)
    XCTAssertFalse(snapshot.metadata.inputDigest.isEmpty)
  }

  func testConversionIsReproducible() throws {
    let document = "example.com\nfoo.cn\nfull:api.example.com\n"
    let first = try convert(document)
    let second = try convert(document)
    XCTAssertEqual(first.rules.map(\.match), second.rules.map(\.match))
    XCTAssertEqual(first.lossReport, second.lossReport)
    XCTAssertEqual(first.metadata.inputDigest, second.metadata.inputDigest)
  }

  // MARK: - 异常规模与损坏输入

  func testAbnormalRuleCountFailsConversion() {
    let tooSmall = GeolocationCNConverter(
      source: source, minimumRuleCount: 100, maximumRuleCount: 10_000)
    XCTAssertThrowsError(
      try tooSmall.convert(
        document: "example.com\n",
        provenance: .init(
          fetchedAt: fetchedAt, upstreamReference: "v", license: "MIT", attribution: "a"),
        provider: { _ in "" })
    ) { error in
      XCTAssertEqual(
        error as? GeolocationCNConverter.ConversionError, .abnormalRuleCount(2))
    }

    let tooLarge = GeolocationCNConverter(
      source: source, minimumRuleCount: 1, maximumRuleCount: 2)
    XCTAssertThrowsError(
      try tooLarge.convert(
        document: "a.com\nb.com\nc.com\n",
        provenance: .init(
          fetchedAt: fetchedAt, upstreamReference: "v", license: "MIT", attribution: "a"),
        provider: { _ in "" })
    )
  }

  func testInvalidDomainEntriesAreRejectedNotFatal() throws {
    let snapshot = try convert(
      """
      domain:*bad.example.com
      full:.also-bad.com
      good.com
      """)
    XCTAssertTrue(snapshot.rules.map(\.match).contains(.domainSuffix("good.com")))
    XCTAssertEqual(snapshot.lossReport.rejected["invalidDomain"], 2)
  }

  // MARK: - 快照存储

  func testSnapshotStoreRoundTripAndVersionGuard() throws {
    let snapshot = try convert("example.com\nfoo.cn\n")
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-rule-snapshot-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("snapshot.json")

    let store = RuleSnapshotStore(fileURL: url)
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(error as? RuleSnapshotError, .missing)
    }
    try store.save(snapshot)
    let loaded = try store.load()
    XCTAssertEqual(loaded.rules.map(\.match), snapshot.rules.map(\.match))
    XCTAssertEqual(loaded.metadata, snapshot.metadata)

    // schema / converter 版本不匹配使加载失败。
    let rawObject = try JSONSerialization.jsonObject(with: Data(contentsOf: url))
    guard var raw = rawObject as? [String: Any] else {
      return XCTFail("snapshot JSON root should be an object")
    }
    raw["schemaVersion"] = 99
    try JSONSerialization.data(withJSONObject: raw).write(to: url)
    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(
        error as? RuleSnapshotError,
        .schemaVersionMismatch(found: 99, expected: RuleSnapshot.currentSchemaVersion))
    }
  }
}
