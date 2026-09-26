import XCTest

@testable import ShadowsocksX_NG2

/// #33 设置主缝：偏好校验与绕过列表解析只通过公开领域入口断言，不依赖
/// SwiftUI 视图实现。
final class ProxySettingsTests: XCTestCase {
  func testFactoryDefaultsAvoidLegacyPortsAndValidate() {
    let settings = ProxySettings()

    XCTAssertEqual(settings.listen.socksPort, 11086)
    XCTAssertEqual(settings.listen.httpPort, 11087)
    XCTAssertEqual(settings.timeoutSeconds, 60)
    XCTAssertFalse(settings.verboseLogging)
    XCTAssertEqual(settings.listen.mode, "tcp_and_udp")
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
    settings.listen.scope = .host(advertisedAddress: "127.0.0.1")
    settings.listen.socksPort = settings.listen.httpPort

    XCTAssertEqual(
      settings.validationErrors,
      [
        .duplicatePort(endpoint: .socks, otherEndpoint: .http, port: 11087),
        .invalidTimeout(0),
        .invalidHostAddress("127.0.0.1"),
      ])
  }
}
