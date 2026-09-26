import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// 内置规则目录（issue #63）：bundle 快照加载与中国直连候选投影。
final class BuiltinRuleCatalogTests: XCTestCase {
  func testGeolocationCNSnapshotLoadsFromBundleOrSourceTree() throws {
    // 优先 bundle（随 App 分发）；测试环境回退到源码树固定快照。
    let snapshot: RuleSnapshot
    if let bundle = try? BuiltinRuleCatalog.loadGeolocationCN() {
      snapshot = bundle
    } else {
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
      legacyListenFileURL: dir.appendingPathComponent("listen.json"),
      credentials: EphemeralCredentialStore())

    var settings = ProxySettings()
    settings.preferredMode = .rule
    settings.ruleDefaultAction = .proxyWhenUnmatched
    try store.save(settings)
    XCTAssertEqual(try store.load().preferredMode, .rule)
    XCTAssertEqual(try store.load().ruleDefaultAction, .proxyWhenUnmatched)

    settings.ruleDefaultAction = .directWhenUnmatched
    try store.save(settings)
    XCTAssertEqual(try store.load().ruleDefaultAction, .directWhenUnmatched)

    // 缺省字段解析为出厂「未匹配时代理」。
    try Data("{}".utf8).write(to: dir.appendingPathComponent("settings.json"))
    XCTAssertEqual(try store.load().ruleDefaultAction, .proxyWhenUnmatched)
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
