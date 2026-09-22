import XCTest

@testable import ShadowsocksX_NG2

/// #33 设置主缝：偏好校验、绕过列表解析与 PAC 用户规则只通过公开领域
/// 入口断言，不依赖 SwiftUI 视图实现。
final class ProxySettingsTests: XCTestCase {
  func testFactoryDefaultsAvoidLegacyPortsAndValidate() {
    let settings = ProxySettings()

    XCTAssertEqual(settings.listen.socksPort, 11086)
    XCTAssertEqual(settings.listen.httpPort, 11087)
    XCTAssertEqual(settings.listen.pacPort, 11089)
    XCTAssertEqual(settings.timeoutSeconds, 60)
    XCTAssertFalse(settings.verboseLogging)
    XCTAssertTrue(settings.listen.udpRelayEnabled == false)
    XCTAssertTrue(settings.validationErrors.isEmpty)
  }

  func testProxyExceptionsSplitCommaChineseCommaAndWhitespaceWithoutDuplicates() {
    var settings = ProxySettings()
    settings.proxyExceptions = "localhost, 127.0.0.1、localhost\n::1"

    XCTAssertEqual(settings.proxyExceptionList, ["localhost", "127.0.0.1", "::1"])
  }

  func testInvalidAdvancedSettingsNameEveryProblem() {
    var settings = ProxySettings()
    settings.timeoutSeconds = 0
    settings.externalPACURL = "file:///tmp/proxy.pac"
    settings.gfwListURL = "ftp://example.com/gfw.txt"
    settings.listen.scope = .host(advertisedAddress: "127.0.0.1")
    settings.listen.socksPort = settings.listen.httpPort

    XCTAssertEqual(
      settings.validationErrors,
      [
        .duplicatePort(endpoint: .socks, otherEndpoint: .http, port: 11087),
        .invalidTimeout(0),
        .invalidHostAddress("127.0.0.1"),
        .invalidExternalPACURL(.unsupportedExternalPACScheme("file")),
        .invalidGFWListURL("ftp://example.com/gfw.txt"),
      ])
  }

  func testPACUserRulesExposeOnlyExplicitBypassRulesAsDirectHosts() {
    XCTAssertEqual(
      PACRuleSet.directHostSuffixes(
        from: "! comment\n@@||example.com^\n||ignored.example^\n@@|https://sub.example/path"
      ),
      ["example.com", "sub.example"])
  }
}
