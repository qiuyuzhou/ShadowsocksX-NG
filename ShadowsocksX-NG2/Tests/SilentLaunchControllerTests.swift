import XCTest

@testable import ShadowsocksX_NG2

/// 静默启动控制器（ADR 0017）：初始值来自持久化；翻转先落盘；持久化失败
/// 保持原值并点名原因，开关呈现不得与下次启动的实际行为脱节。
@MainActor
final class SilentLaunchControllerTests: XCTestCase {
  private var workDir: URL!
  private var store: SilentLaunchStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "silent-launch-controller-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    store = SilentLaunchStore(fileURL: workDir.appendingPathComponent("silent-launch.json"))
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: workDir)
    try super.tearDownWithError()
  }

  func testInitialValueComesFromStore() throws {
    try store.save(silentLaunchEnabled: true)
    XCTAssertTrue(SilentLaunchController(store: store).isEnabled)

    let fresh = SilentLaunchController(
      store: SilentLaunchStore(
        fileURL: workDir.appendingPathComponent("absent.json")))
    XCTAssertFalse(fresh.isEnabled, "无持久化记录按出厂默认：不静默")
  }

  func testEnablePersistsBeforeFlippingPublishedState() throws {
    let controller = SilentLaunchController(store: store)

    controller.setEnabled(true)

    XCTAssertTrue(controller.isEnabled)
    XCTAssertTrue(store.loadSilentLaunchEnabled())
    XCTAssertNil(controller.errorMessage)
  }

  func testDisablePersists() throws {
    try store.save(silentLaunchEnabled: true)
    let controller = SilentLaunchController(store: store)

    controller.setEnabled(false)

    XCTAssertFalse(controller.isEnabled)
    XCTAssertFalse(store.loadSilentLaunchEnabled())
  }

  func testPersistFailureKeepsValueAndNamesReason() throws {
    // AtomicFileWriter 会自愈缺失目录（D5 基线），稳定失败路径是父路径被
    // 普通文件占据。
    let blocker = workDir.appendingPathComponent("blocker")
    try Data().write(to: blocker)
    let controller = SilentLaunchController(
      store: SilentLaunchStore(fileURL: blocker.appendingPathComponent("silent-launch.json")))

    controller.setEnabled(true)

    XCTAssertFalse(controller.isEnabled, "持久化失败不得翻转呈现态")
    XCTAssertNotNil(controller.errorMessage)
  }
}
