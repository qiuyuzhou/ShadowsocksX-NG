import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// Legacy 导入主缝：用属性列表快照模拟旧版 UserDefaults，通过导入结果与持久化
/// 文档观察身份映射、偏好迁移、凭据引用和事务语义；不读取或修改真实 Legacy 数据。
final class LegacyImportTests: XCTestCase {
  private var directory: URL!
  private var catalogURL: URL!
  private var activationURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var settingsStore: TestProxySettingsStore!
  private var marker: TestLegacyImportMarker!
  private var provider: FixedLegacySnapshotProvider!

  override func setUpWithError() throws {
    try super.setUpWithError()
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("legacy-import-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    catalogURL = directory.appendingPathComponent("catalog.json")
    activationURL = directory.appendingPathComponent("activation.json")
    credentials = InMemoryCredentialStore()
    settingsStore = TestProxySettingsStore()
    marker = TestLegacyImportMarker()
    provider = FixedLegacySnapshotProvider(snapshot: try Self.makeSnapshot())
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: directory)
    try super.tearDownWithError()
  }

  func testImportMapsProfilesPreferencesCredentialsAndActiveTarget() throws {
    let service = makeService()

    let outcome = try service.importCurrentSnapshot()

    XCTAssertEqual(outcome.report.importedServerCount, 4)
    XCTAssertEqual(outcome.report.skippedRecords.map(\.index), [4, 5])
    XCTAssertEqual(outcome.report.regeneratedIdentityCount, 3)
    XCTAssertEqual(outcome.report.activeTarget, .imported(NodeID(rawValue: Self.validID)))
    XCTAssertEqual(outcome.loginAtLogin, false)
    XCTAssertEqual(outcome.preferredMode, .externalPAC)
    XCTAssertTrue(marker.completed)

    let document = try CatalogFileStore(fileURL: catalogURL).load()
    let groupID = try XCTUnwrap(document.catalog.rootChildren.first)
    let group = try XCTUnwrap(document.catalog.entry(for: groupID))
    guard case .group(let groupFields) = group.kind else {
      return XCTFail("Legacy 导入应创建手动分组")
    }
    XCTAssertEqual(group.source, .manual)
    XCTAssertEqual(groupFields.children.count, 4)

    let first = try XCTUnwrap(document.catalog.entry(for: groupFields.children[0]))
    guard case .server(let fields) = first.kind else {
      return XCTFail("导入条目应为服务器叶子")
    }
    XCTAssertEqual(first.id, NodeID(rawValue: Self.validID))
    XCTAssertEqual(fields.pluginProgram, "unknown-plugin")
    XCTAssertEqual(
      try credentials.secret(for: fields.passwordRef), "password-1")
    XCTAssertEqual(
      try credentials.secret(for: try XCTUnwrap(fields.pluginOptionsRef)),
      "mode=websocket;host=example.test")

    let settings = try XCTUnwrap(settingsStore.savedSettings)
    XCTAssertEqual(settings.listen.socksPort, 2086)
    XCTAssertEqual(settings.listen.httpPort, 2087)
    XCTAssertEqual(settings.listen.pacPort, 2089)
    XCTAssertEqual(settings.listen.scope, .loopback)
    XCTAssertTrue(settings.listen.udpRelayEnabled)
    XCTAssertEqual(settings.timeoutSeconds, 120)
    XCTAssertTrue(settings.verboseLogging)
    XCTAssertEqual(settings.proxyExceptions, "localhost, example.test")
    XCTAssertEqual(settings.externalPACURL, "https://pac.example.test/proxy.pac")
    XCTAssertEqual(settings.gfwListURL, "https://gfw.example.test/list.txt")
    XCTAssertEqual(settings.pacUserRules, "@@||example.test^")
    XCTAssertEqual(settings.preferredMode, .externalPAC)
    XCTAssertEqual(
      settings.enabledModes,
      Set([ProxyModeKind.pac, .global, .externalPAC]))
  }

  func testExplicitReimportCreatesIndependentGroupAndDoesNotRepeatAutomatically() throws {
    let service = makeService()
    _ = try service.importCurrentSnapshot()

    XCTAssertThrowsError(try service.importCurrentSnapshot()) { error in
      XCTAssertEqual(error as? LegacyImportError, .alreadyCompleted)
    }

    let second = try service.importCurrentSnapshot(reimport: true)
    let document = try CatalogFileStore(fileURL: catalogURL).load()
    XCTAssertEqual(document.catalog.rootChildren.count, 2)
    XCTAssertNotEqual(document.catalog.rootChildren[0], document.catalog.rootChildren[1])
    XCTAssertNotEqual(second.activeTargetID, Self.validIDNode)
    XCTAssertTrue(marker.completed)
  }

  func testFailedCommitRestoresCatalogSettingsActivationCredentialsAndMarker() throws {
    let originalID = NodeID(rawValue: "existing-target")
    var originalCatalog = ConfigurationCatalog()
    let originalServer = try originalCatalog.addTestServer("原有节点", id: originalID)
    let originalFields = try XCTUnwrap(originalCatalog.entry(for: originalServer))
    guard case .server(let originalServerFields) = originalFields.kind else {
      return XCTFail("原有夹具应为服务器")
    }
    try credentials.save("original-password", for: originalServerFields.passwordRef)
    try CatalogFileStore(fileURL: catalogURL).save(CatalogDocument(catalog: originalCatalog))
    try ActivationStateFileStore(fileURL: activationURL).save(activeTargetID: originalID)

    settingsStore.settings = ProxySettings(
      timeoutSeconds: 42, proxyExceptions: "original.example")
    let originalSettings = settingsStore.settings
    marker.failWhenSettingCompleted = true
    let service = makeService()

    XCTAssertThrowsError(try service.importCurrentSnapshot()) { error in
      guard case .commitFailed = error as? LegacyImportError else {
        return XCTFail("应以事务失败返回，实际：\(error)")
      }
    }

    XCTAssertEqual(try CatalogFileStore(fileURL: catalogURL).load().catalog, originalCatalog)
    XCTAssertEqual(settingsStore.settings, originalSettings)
    XCTAssertEqual(
      try ActivationStateFileStore(fileURL: activationURL).loadActiveTargetID(), originalID)
    XCTAssertEqual(
      try credentials.secret(for: originalServerFields.passwordRef), "original-password")
    XCTAssertEqual(credentials.storageCount, 1)
    XCTAssertFalse(marker.completed)
  }

  func testNonLoopbackLegacyListenersAreForcedToLoopbackAndReported() throws {
    let snapshot = try LegacySnapshot(
      propertyList: [
        "ServerProfiles": [Self.validProfile()],
        "LocalSocks5.ListenAddress": "192.168.1.20",
        "LocalHTTP.ListenAddress": "127.0.0.1",
        "PacServer.BindToLocalhost": false,
      ],
      userRules: nil)
    provider.snapshot = snapshot

    let outcome = try makeService().importCurrentSnapshot()

    XCTAssertTrue(outcome.report.warnings.contains { $0.contains("回环") })
    XCTAssertEqual(try XCTUnwrap(settingsStore.savedSettings).listen.scope, .loopback)
  }
}

extension LegacyImportTests {
  func testValidProfileWithoutLegacyIDGetsNewIdentityAndCounts() throws {
    var profile = Self.validProfile()
    profile.removeValue(forKey: "Id")
    provider.snapshot = try LegacySnapshot(
      propertyList: ["ServerProfiles": [profile]], userRules: nil)

    let outcome = try makeService().importCurrentSnapshot()

    XCTAssertEqual(outcome.report.importedServerCount, 1)
    XCTAssertEqual(outcome.report.regeneratedIdentityCount, 1)
    XCTAssertNil(outcome.activeTargetID)
  }

  fileprivate static let validID = "11111111-1111-4111-8111-111111111111"
  fileprivate static let duplicateID = "22222222-2222-4222-8222-222222222222"
  fileprivate static let validIDNode = NodeID(rawValue: validID)

  fileprivate static func validProfile() -> [String: Any] {
    [
      "Id": validID,
      "ServerHost": "203.0.113.7",
      "ServerPort": 8388,
      "Method": "aes-256-gcm",
      "Password": "password-1",
      "Remark": "香港 01",
      "Plugin": "unknown-plugin",
      "PluginOptions": "mode=websocket;host=example.test",
    ]
  }

  fileprivate static func makeSnapshot() throws -> LegacySnapshot {
    try LegacySnapshot(
      propertyList: [
        "ServerProfiles": [
          validProfile(),
          [
            "Id": "not-a-uuid",
            "ServerHost": "198.51.100.8",
            "ServerPort": 8389,
            "Method": "chacha20-ietf-poly1305",
            "Password": "password-2",
          ],
          [
            "Id": duplicateID,
            "ServerHost": "198.51.100.9",
            "ServerPort": 8390,
            "Method": "aes-128-gcm",
            "Password": "password-3",
          ],
          [
            "Id": duplicateID,
            "ServerHost": "198.51.100.10",
            "ServerPort": 8391,
            "Method": "aes-128-gcm",
            "Password": "password-4",
          ],
          [
            "ServerHost": "not a host",
            "ServerPort": 8392,
            "Method": "aes-128-gcm",
            "Password": "password-5",
          ],
          "not-a-profile",
        ],
        "ActiveServerProfileId": validID,
        "LocalSocks5.ListenPort": 2086,
        "LocalSocks5.ListenAddress": "127.0.0.1",
        "LocalHTTP.ListenPort": 2087,
        "LocalHTTPOn": true,
        "PacServer.ListenPort": 2089,
        "PacServer.BindToLocalhost": true,
        "LocalSocks5.EnableUDPRelay": true,
        "LocalSocks5.Timeout": 120,
        "LocalSocks5.EnableVerboseMode": true,
        "ProxyExceptions": "localhost, example.test",
        "ExternalPACURL": "https://pac.example.test/proxy.pac",
        "GFWListURL": "https://gfw.example.test/list.txt",
        "ShadowsocksRunningMode": "externalPAC",
        "EnableSwitchMode.PAC": true,
        "EnableSwitchMode.Global": true,
        "EnableSwitchMode.Manual": false,
        "EnableSwitchMode.ExternalPAC": true,
        "LaunchAtLogin": false,
      ],
      userRules: "@@||example.test^")
  }

  fileprivate func makeService() -> LegacyImportService {
    LegacyImportService(
      source: provider,
      catalogStore: CatalogFileStore(fileURL: catalogURL),
      settingsStore: settingsStore,
      activationStore: ActivationStateFileStore(fileURL: activationURL),
      credentials: credentials,
      marker: marker)
  }
}

private final class FixedLegacySnapshotProvider: LegacySnapshotProviding {
  var snapshot: LegacySnapshot?

  init(snapshot: LegacySnapshot?) {
    self.snapshot = snapshot
  }

  func readSnapshot() throws -> LegacySnapshot? { snapshot }
}

private final class TestProxySettingsStore: ProxySettingsStoring {
  var settings = ProxySettings()
  var savedSettings: ProxySettings?

  func load() throws -> ProxySettings { settings }

  func save(_ settings: ProxySettings) throws {
    self.settings = settings
    savedSettings = settings
  }

  func reset() throws {}
}

private final class TestLegacyImportMarker: LegacyImportMarkerStoring {
  var completed = false
  var failWhenSettingCompleted = false

  func isCompleted() throws -> Bool { completed }

  func setCompleted(_ completed: Bool) throws {
    if completed && failWhenSettingCompleted {
      throw TestMarkerError.rejected
    }
    self.completed = completed
  }
}

private enum TestMarkerError: Error {
  case rejected
}
