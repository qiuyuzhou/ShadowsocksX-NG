import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// Domain mode availability is the single policy shared by the menu and
/// runtime mode entry points.
final class ProxyModeAvailabilityTests: XCTestCase {
  func testBuiltInModesAreAlwaysAvailableInProductOrder() {
    XCTAssertEqual(
      ProxyMode.availableModes(for: ProxySettings()).map(\.kind),
      [.pac, .global, .manual])
  }

  func testValidExternalPACIsAppendedAfterBuiltInModes() {
    let url = URL(string: "https://pac.example.test/proxy.pac")!
    let settings = ProxySettings(externalPACURL: url.absoluteString)

    XCTAssertEqual(
      ProxyMode.availableModes(for: settings),
      [.pac, .global, .manual, .externalPAC(url)])
  }

  func testInvalidExternalPACValuesAreNotAvailable() {
    let values = [
      "ftp://pac.example.test/proxy.pac",
      "https://",
      "https://user:password@pac.example.test/proxy.pac",
      "https://pac.example.test/\(String(repeating: "a", count: 2048))",
    ]

    for value in values {
      XCTAssertEqual(
        ProxyMode.availableModes(for: ProxySettings(externalPACURL: value)).map(\.kind),
        [.pac, .global, .manual],
        "无效的外部 PAC 不应进入可选模式：\(value)")
    }
  }
}
