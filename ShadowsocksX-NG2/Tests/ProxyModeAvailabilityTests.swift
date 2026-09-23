import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// Domain mode availability is the single policy shared by the menu and
/// runtime mode entry points.
final class ProxyModeAvailabilityTests: XCTestCase {
  func testBuiltInModesAreAlwaysAvailableInProductOrder() {
    XCTAssertEqual(
      ProxyMode.availableModes.map(\.kind),
      [.pac, .global])
  }
}
