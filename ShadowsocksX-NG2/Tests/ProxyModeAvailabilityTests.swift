import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// Domain mode availability is the single policy shared by the menu and
/// runtime mode entry points.
final class ProxyModeAvailabilityTests: XCTestCase {
  func testBuiltInModesAreAlwaysAvailableInProductOrder() {
    XCTAssertEqual(
      ProxyMode.availableModes.map(\.kind),
      [.rule, .global, .direct])
  }

  func testDirectModeUsesLocalSOCKSAndIncludesFixedBypasses() throws {
    let document = SslocalRuntimeDocument(servers: [], listen: SslocalListenSettings())

    let configuration = try ProxyMode.direct.systemProxyConfiguration(for: document)

    XCTAssertEqual(
      configuration.target,
      .socks(host: "127.0.0.1", port: SslocalListenSettings.defaultSocksPort))
    XCTAssertEqual(
      configuration.exceptions,
      FixedLocalProxyRanges.systemProxyExceptions)
  }

  /// 全局模式（issue #62）：系统 SOCKS 投影 + 固定本地例外，与直连共用同一
  /// 安全范围；公网路由由 ACL 决定，不由系统例外决定。
  func testGlobalModeUsesLocalSOCKSAndIncludesFixedBypasses() throws {
    let document = SslocalRuntimeDocument(servers: [], listen: SslocalListenSettings())

    let configuration = try ProxyMode.global.systemProxyConfiguration(for: document)

    XCTAssertEqual(
      configuration.target,
      .socks(host: "127.0.0.1", port: SslocalListenSettings.defaultSocksPort))
    XCTAssertEqual(
      configuration.exceptions,
      FixedLocalProxyRanges.systemProxyExceptions)
    XCTAssertFalse(
      configuration.exceptions?.contains("100.64.0.0/10") ?? true,
      "不加入 CGNAT")
  }
}
