import XCTest

@testable import ShadowsocksX_NG2

/// 静默启动偏好持久化（ADR 0017，UserDefaults 形态）：往返无损；键缺失与
/// 外部错误类型按安全侧恢复「不静默」；初版文件形态走一次性迁移。
/// 套件实例 + teardown 移除持久域，不触碰生产 defaults（测试封闭性公约）。
final class SilentLaunchStoreTests: XCTestCase {
  private var suiteName: String!
  private var defaults: UserDefaults!
  private var store: SilentLaunchStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    suiteName = "silent-launch-store-tests-\(UUID().uuidString)"
    defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    store = SilentLaunchStore(defaults: defaults)
  }

  override func tearDownWithError() throws {
    defaults.removePersistentDomain(forName: suiteName)
    try super.tearDownWithError()
  }

  // MARK: 缺失与错误类型

  func testMissingKeyLoadsAsNotSilent() {
    XCTAssertFalse(store.loadSilentLaunchEnabled(), "键缺失按出厂默认：不静默")
  }

  func testForeignTypeLoadsAsNotSilentOnTheSafeSide() {
    // cfprefs 无「损坏」可观测性：外部写入的错误类型按安全侧回落默认。
    defaults.set("yes", forKey: "silentLaunch")

    XCTAssertFalse(store.loadSilentLaunchEnabled())
  }

  // MARK: 往返无损

  func testSaveAndLoadRoundTripBothValues() {
    store.save(silentLaunchEnabled: true)
    XCTAssertTrue(store.loadSilentLaunchEnabled())

    store.save(silentLaunchEnabled: false)
    XCTAssertFalse(store.loadSilentLaunchEnabled())
  }

  // MARK: 初版文件形态（ADR 0017）的一次性迁移

  func testMigrateLegacyFileKeepsValueAndRemovesFile() throws {
    let fileURL = try legacyFile(with: #"{"version": 1, "silentLaunchEnabled": true}"#)

    SilentLaunchStore.migrateLegacyFileIfPresent(at: fileURL, into: defaults)

    XCTAssertTrue(store.loadSilentLaunchEnabled())
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testMigrateLegacyFileWithForeignVersionWritesNothingButRemovesFile() throws {
    let fileURL = try legacyFile(with: #"{"version": 99, "silentLaunchEnabled": true}"#)

    SilentLaunchStore.migrateLegacyFileIfPresent(at: fileURL, into: defaults)

    XCTAssertFalse(store.loadSilentLaunchEnabled(), "版本未知按安全侧：不静默")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testMigrateLegacyCorruptFileWritesNothingButRemovesFile() throws {
    let fileURL = try legacyFile(with: "{ not json {{{")

    SilentLaunchStore.migrateLegacyFileIfPresent(at: fileURL, into: defaults)

    XCTAssertFalse(store.loadSilentLaunchEnabled(), "损坏按安全侧：不静默")
    XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
  }

  func testMigrateWithoutLegacyFileIsNoOp() {
    let fileURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("silent-launch-migrate-\(UUID().uuidString)")
      .appendingPathComponent("absent.json")

    SilentLaunchStore.migrateLegacyFileIfPresent(at: fileURL, into: defaults)

    XCTAssertFalse(store.loadSilentLaunchEnabled())
  }

  private func legacyFile(with contents: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("silent-launch-migrate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let fileURL = directory.appendingPathComponent("silent-launch.json")
    try contents.write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
  }
}
