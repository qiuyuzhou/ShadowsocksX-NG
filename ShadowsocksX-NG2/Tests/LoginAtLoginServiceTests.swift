import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
  private var defaults: UserDefaults!
  private var defaultsSuiteName: String!

  override func setUpWithError() throws {
    defaultsSuiteName = "ssxng-login-tests-\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsSuiteName))
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: defaultsSuiteName)
    defaults = nil
    defaultsSuiteName = nil
  }

  func testDefaultIntentRegistersAtLaunch() {
    let service = FakeLoginItemService()
    let controller = LaunchAtLoginController(service: service, defaults: defaults)

    controller.syncAtLaunch()

    XCTAssertTrue(controller.isEnabled)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(controller.status, .registered)
  }

  func testToggleUnregistersAndPersistsAcrossControllerInstances() {
    let service = FakeLoginItemService()
    let controller = LaunchAtLoginController(service: service, defaults: defaults)

    controller.setEnabled(false)

    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(service.unregisterCount, 1)
    let restored = LaunchAtLoginController(service: service, defaults: defaults)
    XCTAssertFalse(restored.isEnabled)
  }

  func testResetReturnsToEnabledDefault() {
    let service = FakeLoginItemService()
    let controller = LaunchAtLoginController(service: service, defaults: defaults)
    controller.setEnabled(false)

    controller.resetToDefaults()

    XCTAssertTrue(controller.isEnabled)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertNil(defaults.object(forKey: LaunchAtLoginController.preferenceKey))
  }

  private final class FakeLoginItemService: LaunchAtLoginControlling {
    var status: LoginItemStatus = .notRegistered
    var registerCount = 0
    var unregisterCount = 0

    func register() throws {
      registerCount += 1
      status = .registered
    }

    func unregister() throws {
      unregisterCount += 1
      status = .notRegistered
    }
  }
}
