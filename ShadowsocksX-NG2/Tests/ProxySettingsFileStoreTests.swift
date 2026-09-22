import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// #33 偏好持久化缝：敏感 URL 只进入凭据存储，设置文件只保存引用；重置
/// 不触碰配置目录与活动目标使用的其他文件。
final class ProxySettingsFileStoreTests: XCTestCase {
  private var directory: URL!
  private var store: ProxySettingsFileStore!
  private var credentials: InMemoryCredentialStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-settings-tests-\(UUID().uuidString)", isDirectory: true)
    credentials = InMemoryCredentialStore()
    store = ProxySettingsFileStore(
      fileURL: directory.appendingPathComponent("settings.json"),
      legacyListenFileURL: directory.appendingPathComponent("listen-settings.json"),
      credentials: credentials)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  private func writeRaw(_ text: String) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(text.utf8).write(to: store.fileURL)
  }

  func testRoundTripKeepsPreferencesButDoesNotWriteRemoteURLsToSettingsFile() throws {
    var settings = ProxySettings()
    settings.listen.scope = .host(advertisedAddress: "192.168.2.89")
    settings.listen.socksPort = 2086
    settings.listen.httpProxyEnabled = false
    settings.listen.httpPort = 2087
    settings.listen.pacPort = 2089
    settings.listen.udpRelayEnabled = true
    settings.timeoutSeconds = 120
    settings.verboseLogging = true
    settings.proxyExceptions = "localhost, 127.0.0.1"
    settings.externalPACURL = "https://pac.example.test/proxy.pac?token=secret"
    settings.gfwListURL = "https://lists.example.test/gfw.txt?token=secret"
    settings.pacUserRules = "@@||example.com^"
    settings.preferredMode = .externalPAC

    try store.save(settings)

    XCTAssertEqual(try store.load(), settings)
    let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertFalse(raw.contains("pac.example.test"))
    XCTAssertFalse(raw.contains("lists.example.test"))
    XCTAssertFalse(raw.contains("token=secret"))
    XCTAssertNotNil(try credentials.secret(for: ProxySettingsFileStore.externalPACReference))
    XCTAssertNotNil(try credentials.secret(for: ProxySettingsFileStore.gfwListReference))
  }

  func testLoadPreservesPersistedLegacyDefaultPortsWithoutImplicitMigration() throws {
    var settings = ProxySettings()
    settings.listen.socksPort = 1086
    settings.listen.httpPort = 1087
    settings.listen.pacPort = 1089
    try store.save(settings)

    let loaded = try store.load()

    XCTAssertEqual(loaded.listen.socksPort, 1086)
    XCTAssertEqual(loaded.listen.httpPort, 1087)
    XCTAssertEqual(loaded.listen.pacPort, 1089)
  }

  func testMissingPortFieldsUseNewFactoryDefaults() throws {
    try writeRaw("{}")

    XCTAssertEqual(try store.load(), ProxySettings())
  }

  func testInvalidSaveDoesNotTouchExistingSettings() throws {
    try store.save(ProxySettings())
    var invalid = ProxySettings()
    invalid.timeoutSeconds = 0

    XCTAssertThrowsError(try store.save(invalid)) { error in
      XCTAssertEqual(
        error as? ProxySettingsStoreError,
        .invalid([.invalidTimeout(0)]))
    }
    XCTAssertEqual(try store.load(), ProxySettings())
  }

  func testMissingNewFileMigratesLegacyListenSettingsAndUsesNewDefaults() throws {
    var legacy = SslocalListenSettings()
    legacy.socksPort = 2086
    legacy.pacPort = 2089
    try ListenSettingsFileStore(fileURL: store.legacyListenFileURL).save(legacy)

    let loaded = try store.load()

    XCTAssertEqual(loaded.listen, legacy)
    XCTAssertEqual(loaded.timeoutSeconds, 60)
    XCTAssertEqual(loaded.gfwListURL, ProxySettings.defaultGFWListURL)
  }

  func testResetRemovesSettingsAndCredentialReferencesButLeavesFactoryDefaultsAvailable() throws {
    var settings = ProxySettings()
    settings.externalPACURL = "https://pac.example.test/proxy.pac"
    try store.save(settings)
    try store.reset()

    XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    XCTAssertNil(try credentials.secret(for: ProxySettingsFileStore.externalPACReference))
    XCTAssertEqual(try store.load(), ProxySettings())
  }
}
