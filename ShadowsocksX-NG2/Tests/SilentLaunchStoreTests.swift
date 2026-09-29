import XCTest

@testable import ShadowsocksX_NG2

/// 静默启动偏好持久化（ADR 0017）：往返无损、缺失/损坏按安全侧恢复「不静默」。
final class SilentLaunchStoreTests: XCTestCase {
  private var workDir: URL!
  private var store: SilentLaunchStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("silent-launch-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    store = SilentLaunchStore(fileURL: workDir.appendingPathComponent("silent-launch.json"))
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: workDir)
    try super.tearDownWithError()
  }

  // MARK: 缺失与损坏

  func testMissingFileLoadsAsNotSilent() {
    XCTAssertFalse(store.loadSilentLaunchEnabled(), "文件缺失按出厂默认：不静默")
  }

  func testBrokenJSONLoadsAsNotSilentOnTheSafeSide() throws {
    try "{ not json {{{".write(to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(store.loadSilentLaunchEnabled(), "损坏按安全侧恢复：不静默")
  }

  func testUnknownSchemaVersionLoadsAsNotSilent() throws {
    try #"{"version": 99, "silentLaunchEnabled": true}"#.write(
      to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertFalse(store.loadSilentLaunchEnabled())
  }

  // MARK: 往返无损

  func testSaveAndLoadRoundTripBothValues() throws {
    try store.save(silentLaunchEnabled: true)
    XCTAssertTrue(store.loadSilentLaunchEnabled())

    try store.save(silentLaunchEnabled: false)
    XCTAssertFalse(store.loadSilentLaunchEnabled())
  }

  func testSaveFailureWhenParentPathIsARegularFile() throws {
    // AtomicFileWriter 会自愈缺失目录（D5 基线），真正稳定的失败路径是
    // 父路径被普通文件占据：目录创建必败。
    let blocker = workDir.appendingPathComponent("blocker")
    try Data().write(to: blocker)
    let broken = SilentLaunchStore(fileURL: blocker.appendingPathComponent("silent-launch.json"))

    XCTAssertThrowsError(try broken.save(silentLaunchEnabled: true)) { error in
      guard case SilentLaunchStore.PersistenceError.ioFailure = error else {
        return XCTFail("写入失败应携带 ioFailure：\(error)")
      }
    }
  }
}
