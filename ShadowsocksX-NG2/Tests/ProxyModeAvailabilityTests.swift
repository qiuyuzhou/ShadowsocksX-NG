import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// Domain mode availability is the single policy shared by the menu and
/// runtime mode entry points.
final class ProxyModeAvailabilityTests: XCTestCase {
  func testBuiltInModesAreAlwaysAvailableInProductOrder() {
    XCTAssertEqual(
      ProxyMode.availableModes.map(\.kind),
      [.pac, .global, .direct])
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
}
