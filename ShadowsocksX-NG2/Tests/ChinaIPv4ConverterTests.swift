import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// china-operator-ip IPv4 CIDR 转换器（issue #64）：规范化、去重、拒绝计数、
/// 异常规模失败与来源元数据。
final class ChinaIPv4ConverterTests: XCTestCase {
  private let source = RuleSourceIdentity(
    kind: .chinaIPv4,
    upstreamVersion: "test-commit",
    label: "china-operator-ip")

  private var converter: ChinaIPv4Converter {
    // 测试夹具：放宽规模与拒绝率阈值，单独用例再收紧。
    ChinaIPv4Converter(
      source: source, minimumRuleCount: 1, maximumRuleCount: 10_000,
      maximumRejectionPercent: 100)
  }

  private let fetchedAt = Date(timeIntervalSince1970: 1_764_000_000)

  private func convert(
    _ document: String,
    previousRuleCount: Int? = nil
  ) throws -> RuleSnapshot {
    try converter.convert(
      document: document,
      provenance: .init(
        fetchedAt: fetchedAt,
        upstreamReference: "test://china-operator-ip@v1",
        license: "MIT",
        attribution: "test attribution"),
      previousRuleCount: previousRuleCount)
  }

  // MARK: - 解析与规范化

  func testParsesAndNormalizesIPv4CIDRs() throws {
    let snapshot = try convert(
      """
      # comment
      1.0.1.0/24
      1.0.2.5/23

      203.0.113.7
      """)
    let values = snapshot.rules.map { rule -> String in
      switch rule.match {
      case .ipv4CIDR(let value): return value
      default: return "non-cidr"
      }
    }
    XCTAssertEqual(values, ["1.0.1.0/24", "1.0.2.0/23", "203.0.113.7/32"])
    XCTAssertTrue(snapshot.rules.allSatisfy { $0.action == .direct })
    XCTAssertEqual(snapshot.rules.allSatisfy { $0.source.kind == .chinaIPv4 }, true)
    XCTAssertEqual(snapshot.lossReport.convertedCount, 3)
    XCTAssertEqual(snapshot.lossReport.rejected["invalidCIDR"] ?? 0, 0)
  }

  func testDeduplicatesNormalizedCIDRs() throws {
    let snapshot = try convert(
      """
      1.0.1.0/24
      1.0.1.0/24
      1.0.1.7/24
      """)
    XCTAssertEqual(snapshot.rules.count, 1)
    XCTAssertEqual(snapshot.lossReport.skipped["duplicate"], 2)
    XCTAssertEqual(snapshot.lossReport.convertedCount, 1)
  }

  func testCountsRejectedInvalidEntries() throws {
    let snapshot = try convert(
      """
      1.0.1.0/24
      not-a-cidr
      999.999.999.999/33
      ::1/128
      2.0.0.0/8
      """)
    XCTAssertEqual(snapshot.rules.count, 2)
    XCTAssertEqual(snapshot.lossReport.rejected["invalidCIDR"], 3)
  }

  // MARK: - 转换失败

  func testEmptyInputFails() {
    XCTAssertThrowsError(try convert("")) { error in
      XCTAssertEqual(error as? ChinaIPv4Converter.ConversionError, .emptyInput)
    }
    XCTAssertThrowsError(try convert("# only comments\n\n")) { error in
      XCTAssertEqual(error as? ChinaIPv4Converter.ConversionError, .emptyInput)
    }
  }

  func testAllEntriesInvalidFails() {
    XCTAssertThrowsError(
      try convert("not-a-cidr\nalso-bad\n")
    ) { error in
      XCTAssertEqual(error as? ChinaIPv4Converter.ConversionError, .allEntriesInvalid)
    }
  }

  func testAbnormalFormatRejectionRateFails() {
    // 默认 5% 拒绝率阈值：20 坏 / 30 代码行 ≈ 67% 应阻止。
    let strict = ChinaIPv4Converter(
      source: source, minimumRuleCount: 1, maximumRuleCount: 10_000)
    let bad = (0..<20).map { _ in "not-a-cidr" }.joined(separator: "\n")
    let good = (0..<10).map { "10.\($0).0.0/24" }.joined(separator: "\n")
    XCTAssertThrowsError(
      try strict.convert(
        document: bad + "\n" + good + "\n",
        provenance: .init(
          fetchedAt: fetchedAt, upstreamReference: "u", license: "MIT", attribution: "a"))
    ) { error in
      XCTAssertEqual(
        error as? ChinaIPv4Converter.ConversionError,
        .abnormalFormat(rejected: 20, total: 30))
    }
  }

  func testAbnormalRuleCountFails() {
    let tiny = ChinaIPv4Converter(source: source, minimumRuleCount: 5, maximumRuleCount: 10_000)
    XCTAssertThrowsError(
      try tiny.convert(
        document: "1.0.0.0/24\n1.0.1.0/24\n",
        provenance: .init(
          fetchedAt: fetchedAt, upstreamReference: "u", license: "MIT", attribution: "a"))
    ) { error in
      XCTAssertEqual(error as? ChinaIPv4Converter.ConversionError, .abnormalRuleCount(2))
    }

    let huge = ChinaIPv4Converter(source: source, minimumRuleCount: 1, maximumRuleCount: 2)
    XCTAssertThrowsError(
      try huge.convert(
        document: "1.0.0.0/24\n1.0.1.0/24\n1.0.2.0/24\n",
        provenance: .init(
          fetchedAt: fetchedAt, upstreamReference: "u", license: "MIT", attribution: "a"))
    ) { error in
      XCTAssertEqual(error as? ChinaIPv4Converter.ConversionError, .abnormalRuleCount(3))
    }
  }

  func testAbnormalScaleChangeFails() throws {
    // 3 条相对上一份 10 条：低于 50% 下限。
    XCTAssertThrowsError(
      try convert("1.0.0.0/24\n1.0.1.0/24\n1.0.2.0/24\n", previousRuleCount: 10)
    ) { error in
      XCTAssertEqual(
        error as? ChinaIPv4Converter.ConversionError,
        .abnormalScaleChange(found: 3, previous: 10))
    }
    // 25 条相对上一份 10 条：高于 200% 上限。
    let many = (0..<25).map { "10.\($0).0.0/24" }.joined(separator: "\n")
    XCTAssertThrowsError(try convert(many, previousRuleCount: 10)) { error in
      XCTAssertEqual(
        error as? ChinaIPv4Converter.ConversionError,
        .abnormalScaleChange(found: 25, previous: 10))
    }
    // 落在区间内通过。
    let snapshot = try convert("1.0.0.0/24\n1.0.1.0/24\n1.0.2.0/24\n", previousRuleCount: 4)
    XCTAssertEqual(snapshot.rules.count, 3)
  }

  // MARK: - 元数据

  func testSnapshotMetadataAndSchema() throws {
    let snapshot = try convert("1.0.1.0/24\n")
    XCTAssertEqual(snapshot.schemaVersion, RuleSnapshot.currentSchemaVersion)
    XCTAssertEqual(snapshot.metadata.source.kind, .chinaIPv4)
    XCTAssertEqual(snapshot.metadata.source.upstreamVersion, "test-commit")
    XCTAssertEqual(snapshot.metadata.upstreamReference, "test://china-operator-ip@v1")
    XCTAssertEqual(snapshot.metadata.license, "MIT")
    XCTAssertEqual(snapshot.metadata.attribution, "test attribution")
    XCTAssertEqual(snapshot.metadata.fetchedAt, fetchedAt)
    XCTAssertEqual(
      snapshot.metadata.converterVersion, RuleSnapshotMetadata.currentConverterVersion)
    XCTAssertEqual(
      snapshot.metadata.inputDigest,
      ProxyACLDocument.digest(Data("1.0.1.0/24\n".utf8)))
    XCTAssertEqual(snapshot.lossReport.notes, ["china-ipv4-direct-candidates"])
    XCTAssertTrue(snapshot.absorbed.isEmpty)
  }

  func testSnapshotRoundTripsThroughStore() throws {
    let snapshot = try convert("1.0.1.0/24\n1.0.2.0/23\n")
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-china-ipv4-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("snapshot.json")

    let store = RuleSnapshotStore(fileURL: url)
    try store.save(snapshot)
    let loaded = try store.load()
    XCTAssertEqual(loaded.rules.map(\.match), snapshot.rules.map(\.match))
    XCTAssertEqual(loaded.metadata, snapshot.metadata)
    XCTAssertEqual(
      loaded.metadata.converterVersion, RuleSnapshotMetadata.currentConverterVersion)
  }
}
