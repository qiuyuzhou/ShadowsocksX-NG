import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// 内置规则目录（issue #63）：bundle 快照加载与中国直连候选投影。
final class BuiltinRuleCatalogTests: XCTestCase {
  func testGeolocationCNSnapshotLoadsFromBundleOrSourceTree() throws {
    // 优先 bundle（随 App 分发）；测试环境回退到源码树固定快照。
    let snapshot: RuleSnapshot
    do {
      snapshot = try BuiltinRuleCatalog.loadGeolocationCN()
    } catch {
      let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // ShadowsocksX-NG2/
        .appendingPathComponent("Vendor/rules/geolocation-cn/snapshot.json")
      snapshot = try RuleSnapshotStore(fileURL: sourceURL).load()
    }

    XCTAssertEqual(snapshot.schemaVersion, RuleSnapshot.currentSchemaVersion)
    XCTAssertEqual(snapshot.metadata.source.kind, .geolocationCN)
    XCTAssertEqual(
      snapshot.metadata.converterVersion, RuleSnapshotMetadata.currentConverterVersion)
    XCTAssertFalse(snapshot.metadata.license.isEmpty)
    XCTAssertFalse(snapshot.metadata.attribution.isEmpty)
    XCTAssertFalse(snapshot.metadata.inputDigest.isEmpty)
    XCTAssertFalse(snapshot.metadata.upstreamReference.isEmpty)

    let rules = BuiltinRuleCatalog.chinaDirectRules(from: snapshot)
    XCTAssertFalse(rules.isEmpty)
    XCTAssertTrue(rules.allSatisfy { $0.action == .direct })
    XCTAssertTrue(
      rules.contains { $0.match == .domainSuffix("cn") },
      "快照应含 .cn 后缀直连规则")

    // .cn 吸收后不应再有独立 .cn 域名条目。
    let independentCN = rules.filter {
      switch $0.match {
      case .domainSuffix(let value): return value.hasSuffix(".cn") && value != "cn"
      case .domainExact(let value): return value.hasSuffix(".cn")
      default: return false
      }
    }
    XCTAssertTrue(independentCN.isEmpty, "同动作 .cn 域名应已被吸收")
  }

  /// china-ipv4 快照（issue #64）：从 bundle 或源码树加载，直连候选为 IPv4 CIDR。
  func testChinaIPv4SnapshotLoadsFromBundleOrSourceTree() throws {
    let snapshot: RuleSnapshot
    do {
      snapshot = try BuiltinRuleCatalog.loadChinaIPv4()
    } catch {
      let sourceURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // ShadowsocksX-NG2/
        .appendingPathComponent("Vendor/rules/china-ipv4/snapshot.json")
      snapshot = try RuleSnapshotStore(fileURL: sourceURL).load()
    }

    XCTAssertEqual(snapshot.schemaVersion, RuleSnapshot.currentSchemaVersion)
    XCTAssertEqual(snapshot.metadata.source.kind, .chinaIPv4)
    XCTAssertEqual(
      snapshot.metadata.converterVersion, RuleSnapshotMetadata.currentConverterVersion)
    XCTAssertFalse(snapshot.metadata.license.isEmpty)
    XCTAssertFalse(snapshot.metadata.attribution.isEmpty)
    XCTAssertFalse(snapshot.metadata.inputDigest.isEmpty)
    XCTAssertFalse(snapshot.metadata.upstreamReference.isEmpty)

    let rules = BuiltinRuleCatalog.chinaDirectRules(from: snapshot)
    XCTAssertFalse(rules.isEmpty)
    XCTAssertTrue(rules.allSatisfy { $0.action == .direct })
    XCTAssertTrue(
      rules.allSatisfy {
        if case .ipv4CIDR = $0.match { return true }
        return false
      }, "china-ipv4 快照应只含 IPv4 CIDR 直连候选")
  }

  /// gfwlist 快照（issue #65）：从 bundle 或源码树加载，代理候选为域名后缀。
  func testGFWListSnapshotLoadsFromBundleOrSourceTree() throws {
    let snapshot: RuleSnapshot
    do {
      snapshot = try BuiltinRuleCatalog.loadGFWList()
    } catch {
      snapshot = try loadSourceTreeSnapshot(path: "Vendor/rules/gfwlist/snapshot.json")
    }

    XCTAssertEqual(snapshot.schemaVersion, RuleSnapshot.currentSchemaVersion)
    XCTAssertEqual(snapshot.metadata.source.kind, .gfwlist)
    XCTAssertEqual(
      snapshot.metadata.converterVersion, RuleSnapshotMetadata.currentConverterVersion)
    XCTAssertFalse(snapshot.metadata.license.isEmpty)
    XCTAssertFalse(snapshot.metadata.attribution.isEmpty)
    XCTAssertFalse(snapshot.metadata.inputDigest.isEmpty)
    XCTAssertFalse(snapshot.metadata.upstreamReference.isEmpty)

    let rules = BuiltinRuleCatalog.gfwlistRules(from: snapshot)
    XCTAssertFalse(rules.isEmpty)
    XCTAssertTrue(
      rules.allSatisfy {
        if case .domainSuffix = $0.match { return true }
        return false
      }, "gfwlist 快照候选应为域名后缀")

    // 损失报告保留来源、摘要、许可证/归属与转换损失（含遮蔽例外）。
    XCTAssertGreaterThanOrEqual(snapshot.lossReport.skipped["shadowedException"] ?? 0, 1)
    XCTAssertFalse(snapshot.lossReport.notes.isEmpty)
    XCTAssertEqual(snapshot.absorbed.count, snapshot.lossReport.skipped["shadowedException"] ?? 0)
    XCTAssertEqual(snapshot.lossReport.absorbedCount, snapshot.absorbed.count)
  }

  /// 合并投影（issue #64）：域名 + CIDR 直连候选一起进入 ACL 编译输入。
  func testChinaDirectRulesMergeDomainAndCIDRSnapshots() throws {
    let geolocation = try loadSourceTreeSnapshot(path: "Vendor/rules/geolocation-cn/snapshot.json")
    let chinaIPv4 = try loadSourceTreeSnapshot(path: "Vendor/rules/china-ipv4/snapshot.json")
    let merged = BuiltinRuleCatalog.chinaDirectRules(from: [geolocation, chinaIPv4])

    XCTAssertTrue(
      merged.contains { rule in
        if case .domainSuffix("cn") = rule.match { return true }
        return false
      }, "合并结果应含 .cn 域名直连候选")
    XCTAssertTrue(
      merged.contains { rule in
        if case .ipv4CIDR = rule.match { return true }
        return false
      }, "合并结果应含 IPv4 CIDR 直连候选")
    XCTAssertTrue(merged.allSatisfy { $0.action == .direct })
  }

  private func loadSourceTreeSnapshot(path: String) throws -> RuleSnapshot {
    let sourceURL = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent(path)
    return try RuleSnapshotStore(fileURL: sourceURL).load()
  }

  func testRuleDefaultActionLabelsAndFallback() {
    XCTAssertEqual(RuleDefaultAction.proxyWhenUnmatched.label, "未匹配时代理")
    XCTAssertEqual(RuleDefaultAction.directWhenUnmatched.label, "未匹配时直连")
    XCTAssertEqual(RuleDefaultAction.proxyWhenUnmatched.fallbackAction, .proxy)
    XCTAssertEqual(RuleDefaultAction.directWhenUnmatched.fallbackAction, .direct)
    XCTAssertEqual(RuleDefaultAction.allCases, [.proxyWhenUnmatched, .directWhenUnmatched])
  }

  func testRuleDefaultActionPersistsAcrossSettingsRoundTrip() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-settings-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    let store = ProxySettingsFileStore(
      fileURL: dir.appendingPathComponent("settings.json"),
      legacyListenFileURL: dir.appendingPathComponent("listen.json"))

    var settings = ProxySettings()
    settings.preferredMode = .rule
    settings.ruleDefaultAction = .proxyWhenUnmatched
    try store.save(settings)
    XCTAssertEqual(try store.load().preferredMode, ProxyModeKind.rule)
    XCTAssertEqual(try store.load().ruleDefaultAction, RuleDefaultAction.proxyWhenUnmatched)

    settings.ruleDefaultAction = .directWhenUnmatched
    try store.save(settings)
    XCTAssertEqual(try store.load().ruleDefaultAction, RuleDefaultAction.directWhenUnmatched)

    // 缺省字段解析为出厂「未匹配时代理」。
    try Data("{}".utf8).write(to: dir.appendingPathComponent("settings.json"))
    XCTAssertEqual(try store.load().ruleDefaultAction, RuleDefaultAction.proxyWhenUnmatched)
  }
}

/// 测试用内存凭据存储：不触 Keychain。
final class EphemeralCredentialStore: CredentialStoring {
  private var storage: [String: String] = [:]

  func secret(for reference: CredentialReference) throws -> String? {
    storage[reference.rawValue]
  }

  func save(_ secret: String, for reference: CredentialReference) throws {
    storage[reference.rawValue] = secret
  }

  func delete(_ reference: CredentialReference) throws {
    storage[reference.rawValue] = nil
  }
}
