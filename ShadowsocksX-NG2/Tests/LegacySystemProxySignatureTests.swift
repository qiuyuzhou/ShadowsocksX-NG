import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// Legacy 系统代理特征判定与端口来源（issue #37）纯函数面。
final class LegacySystemProxySignatureTests: XCTestCase {
  // MARK: - 归属分类（特征值 + 全部启用面匹配）

  func testLegacyPACSignatureClassifiesAsLegacy() {
    let dictionary: [String: Any] = [
      "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
      "ProxyAutoConfigEnable": 1,
      "ProxyAutoConfigURLString": "http://localhost:1089/proxy.pac",
      "ExceptionsList": ["localhost"],
    ]
    XCTAssertEqual(
      LegacySystemProxySignature.classify(dictionary, ports: .factory()),
      .legacy)
  }

  func testLegacyPACSignatureFollowsConfiguredPort() {
    let dictionary: [String: Any] = [
      "ProxyAutoConfigEnable": 1,
      "ProxyAutoConfigURLString": "http://localhost:2089/proxy.pac",
    ]
    XCTAssertEqual(
      LegacySystemProxySignature.classify(dictionary, ports: .factory(pacPort: 2089)),
      .legacy)
  }

  func testLegacySOCKSSignatureClassifiesAsLegacy() {
    var dictionary = LegacySystemProxySignature.emptyDisabled
    dictionary["SOCKSEnable"] = 1
    dictionary["SOCKSProxy"] = "127.0.0.1"
    dictionary["SOCKSPort"] = 1086
    XCTAssertEqual(
      LegacySystemProxySignature.classify(dictionary, ports: .factory()),
      .legacy)
  }

  func testLegacyHTTPAndHTTPSSignaturesClassifyAsLegacy() {
    var dictionary = LegacySystemProxySignature.emptyDisabled
    dictionary["HTTPEnable"] = 1
    dictionary["HTTPProxy"] = "127.0.0.1"
    dictionary["HTTPPort"] = 1087
    dictionary["HTTPSEnable"] = 1
    dictionary["HTTPSProxy"] = "127.0.0.1"
    dictionary["HTTPSPort"] = 1087
    XCTAssertEqual(
      LegacySystemProxySignature.classify(dictionary, ports: .factory()),
      .legacy)
  }

  func testDisabledFacetsOnlyClassifiesAsNone() {
    XCTAssertEqual(
      LegacySystemProxySignature.classify(
        LegacySystemProxySignature.emptyDisabled, ports: .factory()),
      .none)
    XCTAssertEqual(LegacySystemProxySignature.classify([:], ports: .factory()), .none)
  }

  func testForeignPACURLClassifiesAsOther() {
    let dictionary: [String: Any] = [
      "ProxyAutoConfigEnable": 1,
      "ProxyAutoConfigURLString": "https://pac.example.test/proxy.pac",
    ]
    XCTAssertEqual(
      LegacySystemProxySignature.classify(dictionary, ports: .factory()),
      .other)
  }

  func testForeignSOCKSEndpointClassifiesAsOther() {
    var dictionary = LegacySystemProxySignature.emptyDisabled
    dictionary["SOCKSEnable"] = 1
    dictionary["SOCKSProxy"] = "127.0.0.1"
    dictionary["SOCKSPort"] = 64649
    XCTAssertEqual(
      LegacySystemProxySignature.classify(dictionary, ports: .factory()),
      .other)
  }

  func testMixedLegacyAndForeignFacetsClassifyAsOther() {
    var dictionary = LegacySystemProxySignature.emptyDisabled
    dictionary["ProxyAutoConfigEnable"] = 1
    dictionary["ProxyAutoConfigURLString"] = "http://localhost:1089/proxy.pac"
    dictionary["SOCKSEnable"] = 1
    dictionary["SOCKSProxy"] = "127.0.0.1"
    dictionary["SOCKSPort"] = 64649
    XCTAssertEqual(
      LegacySystemProxySignature.classify(dictionary, ports: .factory()),
      .other)
  }

  func testVersionedEndpointOfThisProductIsNotLegacySignature() {
    var dictionary = LegacySystemProxySignature.emptyDisabled
    dictionary["ProxyAutoConfigEnable"] = 1
    dictionary["ProxyAutoConfigURLString"] = "http://localhost:1089/v1/proxy.pac?token=abc"
    XCTAssertEqual(
      LegacySystemProxySignature.classify(dictionary, ports: .factory()),
      .other)
  }

  // MARK: - 清理投影

  func testCleanedDisablesFacetsAndRemovesEndpointsKeepsOtherKeys() {
    let dictionary: [String: Any] = [
      "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": 1087,
      "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": 1087,
      "SOCKSEnable": 1, "SOCKSProxy": "127.0.0.1", "SOCKSPort": 1086,
      "ProxyAutoConfigEnable": 1,
      "ProxyAutoConfigURLString": "http://localhost:1089/proxy.pac",
      "ProxyAutoDiscoveryEnable": 1,
      "ExceptionsList": ["localhost", "example.test"],
    ]

    let cleaned = LegacySystemProxySignature.cleaned(dictionary)

    XCTAssertEqual(cleaned["HTTPEnable"] as? Int, 0)
    XCTAssertEqual(cleaned["HTTPSEnable"] as? Int, 0)
    XCTAssertEqual(cleaned["SOCKSEnable"] as? Int, 0)
    XCTAssertEqual(cleaned["ProxyAutoConfigEnable"] as? Int, 0)
    XCTAssertNil(cleaned["HTTPProxy"])
    XCTAssertNil(cleaned["HTTPPort"])
    XCTAssertNil(cleaned["HTTPSProxy"])
    XCTAssertNil(cleaned["HTTPSPort"])
    XCTAssertNil(cleaned["SOCKSProxy"])
    XCTAssertNil(cleaned["SOCKSPort"])
    XCTAssertNil(cleaned["ProxyAutoConfigURLString"])
    // 非代理端点键保留：绕过列表与自动发现不是 Legacy 数据，不动。
    XCTAssertEqual(cleaned["ExceptionsList"] as? [String], ["localhost", "example.test"])
    XCTAssertEqual(cleaned["ProxyAutoDiscoveryEnable"] as? Int, 1)
  }

  func testCleanedLeavesDisabledFacetEndpointValuesUntouched() {
    // 已启用面是 Legacy 特征（PAC），但禁用面的端点值可能是手工混入的静止
    // 数据——清理只处理启用面，禁用面的键值一律保留。
    let dictionary: [String: Any] = [
      "ProxyAutoConfigEnable": 1,
      "ProxyAutoConfigURLString": "http://localhost:1089/proxy.pac",
      "SOCKSEnable": 0,
      "SOCKSProxy": "10.0.0.7",
      "SOCKSPort": 9999,
    ]

    let cleaned = LegacySystemProxySignature.cleaned(dictionary)

    XCTAssertEqual(cleaned["ProxyAutoConfigEnable"] as? Int, 0)
    XCTAssertNil(cleaned["ProxyAutoConfigURLString"])
    XCTAssertEqual(cleaned["SOCKSEnable"] as? Int, 0)
    XCTAssertEqual(cleaned["SOCKSProxy"] as? String, "10.0.0.7")
    XCTAssertEqual(cleaned["SOCKSPort"] as? Int, 9999)
  }

  // MARK: - Legacy 端口来源

  func testPortsProviderReadsLegacyDefaultsWithFactoryFallback() {
    let defaults = UserDefaults(suiteName: "legacy-handoff-ports-test")!
    defer { defaults.removePersistentDomain(forName: "legacy-handoff-ports-test") }
    defaults.removePersistentDomain(forName: "legacy-handoff-ports-test")
    defaults.set(2086, forKey: "LocalSocks5.ListenPort")
    defaults.set(2089, forKey: "PacServer.ListenPort")
    defaults.set("localhost", forKey: "LocalSocks5.ListenAddress")

    let provider = UserDefaultsLegacyListenPortsProvider(
      defaults: defaults, bundleIdentifier: "legacy-handoff-ports-test")

    XCTAssertEqual(
      provider.currentPorts(),
      LegacyListenPorts(socksPort: 2086, httpPort: 1087, pacPort: 2089, socksAddress: "localhost"))
  }

  func testPortsProviderRejectsInvalidValues() {
    let defaults = UserDefaults(suiteName: "legacy-handoff-ports-invalid-test")!
    defaults.removePersistentDomain(forName: "legacy-handoff-ports-invalid-test")
    defer { defaults.removePersistentDomain(forName: "legacy-handoff-ports-invalid-test") }
    defaults.set(0, forKey: "LocalSocks5.ListenPort")
    defaults.set("nonsense", forKey: "PacServer.ListenPort")

    let provider = UserDefaultsLegacyListenPortsProvider(
      defaults: defaults, bundleIdentifier: "legacy-handoff-ports-invalid-test")

    XCTAssertEqual(provider.currentPorts(), .factory())
  }
}
