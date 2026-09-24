import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class LaunchAtLoginServiceTests: XCTestCase {
  func testStartsOffUntilTheUserEnablesIt() {
    let service = FakeLoginItemService()
    let controller = LaunchAtLoginController(service: service)

    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(controller.status, .notRegistered)
    XCTAssertEqual(service.registerCount, 0, "启动不自动注册,默认关闭")
  }

  func testEnablingRegistersAndReflectsSystemState() {
    let service = FakeLoginItemService()
    let controller = LaunchAtLoginController(service: service)

    controller.setEnabled(true)

    XCTAssertTrue(controller.isEnabled)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(controller.status, .registered)
    XCTAssertNil(controller.errorMessage)
  }

  func testDisablingUnregistersAndReflectsSystemState() {
    let service = FakeLoginItemService()
    let controller = LaunchAtLoginController(service: service)
    controller.setEnabled(true)

    controller.setEnabled(false)

    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(service.unregisterCount, 1)
    XCTAssertEqual(controller.status, .notRegistered)
  }

  func testApprovalPendingCountsAsEnabled() {
    let service = FakeLoginItemService()
    service.status = .requiresApproval
    let controller = LaunchAtLoginController(service: service)

    XCTAssertTrue(controller.isEnabled)
    XCTAssertTrue(controller.requiresApproval)
    XCTAssertEqual(service.registerCount, 0)
  }

  func testRegistrationFailureNamesErrorAndKeepsSystemState() {
    let service = FakeLoginItemService()
    service.registerError = FakeError.system
    let controller = LaunchAtLoginController(service: service)

    controller.setEnabled(true)

    XCTAssertFalse(controller.isEnabled)
    XCTAssertEqual(controller.status, .notRegistered)
    XCTAssertEqual(service.registerCount, 1)
    XCTAssertEqual(controller.errorMessage, AppPresentation.unknownError)
  }

  // MARK: 登录项启动判定(LaunchContext,启动策略输入)

  func testLoginLaunchRequiresEnabledLoginItem() {
    XCTAssertFalse(
      LaunchContext.isLoginItemLaunch(loginItemEnabled: false, systemUptime: 5),
      "登录项未启用时,开机后立即手动启动也不该被当成登录启动")
    XCTAssertTrue(LaunchContext.isLoginItemLaunch(loginItemEnabled: true, systemUptime: 5))
  }

  func testApprovalPendingAndRegisteredCountAsEnabledLoginItem() {
    XCTAssertTrue(LoginItemStatus.registered.countsAsEnabled)
    XCTAssertTrue(LoginItemStatus.requiresApproval.countsAsEnabled)
    XCTAssertFalse(LoginItemStatus.notRegistered.countsAsEnabled)
    XCTAssertFalse(LoginItemStatus.notFound.countsAsEnabled)
  }

  func testUptimeBeyondBootWindowIsManualLaunch() {
    XCTAssertFalse(
      LaunchContext.isLoginItemLaunch(
        loginItemEnabled: true,
        systemUptime: LaunchContext.loginLaunchWindow),
      "窗口期右边界(开区间)之外视为手动启动")
    XCTAssertFalse(
      LaunchContext.isLoginItemLaunch(
        loginItemEnabled: true,
        systemUptime: LaunchContext.loginLaunchWindow + 1))
  }

  private enum FakeError: Error, CustomStringConvertible {
    case system

    var description: String { "fake-system-error" }
  }

  private final class FakeLoginItemService: LaunchAtLoginControlling {
    var status: LoginItemStatus = .notRegistered
    var registerCount = 0
    var unregisterCount = 0
    var registerError: Error?

    func register() throws {
      registerCount += 1
      if let registerError { throw registerError }
      status = .registered
    }

    func unregister() throws {
      unregisterCount += 1
      status = .notRegistered
    }
  }
}
