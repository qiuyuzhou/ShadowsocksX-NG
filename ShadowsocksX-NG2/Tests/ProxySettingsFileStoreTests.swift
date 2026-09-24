import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// #33 偏好持久化缝：GFW List URL 只进入凭据存储，设置文件只保存引用；重置
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

  private func makeWriteFailingStore(credentials: CredentialStoring) throws
    -> ProxySettingsFileStore
  {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let blockedParent = directory.appendingPathComponent("blocked")
    try Data("not a directory".utf8).write(to: blockedParent)
    return ProxySettingsFileStore(
      fileURL: blockedParent.appendingPathComponent("settings.json"),
      legacyListenFileURL: directory.appendingPathComponent("listen-settings.json"),
      credentials: credentials)
  }

  func testRoundTripKeepsPreferencesButDoesNotWriteRemoteURLsToSettingsFile() throws {
    var settings = ProxySettings()
    settings.listen.scope = .host(advertisedAddress: "192.168.2.89")
    settings.listen.socksPort = 2086
    settings.listen.httpPort = 2087
    settings.listen.pacPort = 2089
    settings.timeoutSeconds = 120
    settings.verboseLogging = true
    settings.proxyExceptions = "localhost, 127.0.0.1"
    settings.gfwListURL = "https://lists.example.test/gfw.txt?token=secret"
    settings.pacUserRules = "@@||example.com^"

    try store.save(settings)

    XCTAssertEqual(try store.load(), settings)
    let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertFalse(raw.contains("lists.example.test"))
    XCTAssertFalse(raw.contains("token=secret"))
    XCTAssertFalse(raw.contains("udpRelayEnabled"))
    XCTAssertEqual(try store.load().listen.mode, "tcp_and_udp")
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

  func testUnknownEnabledModesIsIgnoredAndNeverWrittenBack() throws {
    try writeRaw("{\"enabledModes\":[\"global\"],\"preferredMode\":\"pac\"}")

    XCTAssertEqual(try store.load().preferredMode, .pac)
    try store.save(ProxySettings())
    let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertFalse(raw.contains("enabledModes"))
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

  func testSaveFailureRollsBackTheCredentialWhenTheSettingsDocumentCannotBeWritten() throws {
    store = try makeWriteFailingStore(credentials: credentials)
    var next = ProxySettings()
    next.gfwListURL = "https://lists.example.test/new.txt"

    XCTAssertThrowsError(try store.save(next)) { error in
      guard case .ioFailure = error as? ProxySettingsStoreError else {
        return XCTFail("文件写入失败应保留为 typed io failure，实际为 \(error)")
      }
    }
    XCTAssertNil(try credentials.secret(for: ProxySettingsFileStore.gfwListReference))
  }

  func testPartialCredentialRollbackIsTypedAndNeverLooksLikeSuccess() throws {
    let failingCredentials = SelectiveCredentialStore()
    store = try makeWriteFailingStore(credentials: failingCredentials)
    failingCredentials.failDelete = true
    var next = ProxySettings()
    next.gfwListURL = "https://lists.example.test/new.txt"

    XCTAssertThrowsError(try store.save(next)) { error in
      XCTAssertEqual(error as? ProxySettingsStoreError, .rollbackFailed)
    }
    XCTAssertEqual(
      try failingCredentials.secret(for: ProxySettingsFileStore.gfwListReference),
      next.gfwListURL)
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
    settings.gfwListURL = "https://lists.example.test/gfw.txt"
    try store.save(settings)
    try store.reset()

    XCTAssertFalse(FileManager.default.fileExists(atPath: store.fileURL.path))
    XCTAssertNil(try credentials.secret(for: ProxySettingsFileStore.gfwListReference))
    XCTAssertEqual(try store.load(), ProxySettings())
  }
}

private final class SelectiveCredentialStore: CredentialStoring {
  private var values: [CredentialReference: String] = [:]
  var failDelete = false

  func save(_ secret: String, for reference: CredentialReference) throws {
    values[reference] = secret
  }

  func secret(for reference: CredentialReference) throws -> String? {
    values[reference]
  }

  func delete(_ reference: CredentialReference) throws {
    if failDelete {
      throw CredentialStoreError.keychainStatus(-25300)
    }
    values.removeValue(forKey: reference)
  }
}
