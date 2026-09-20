import XCTest

@testable import ShadowsocksX_NG2

/// 持久化缝：往返无损、文件缺失/损坏行为明确、权限基线、不含明文秘密
/// （票 #25 验收项）。
final class CatalogFileStoreTests: XCTestCase {
  private var workDir: URL!
  private var store: CatalogFileStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("catalog-file-store-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    store = CatalogFileStore(fileURL: workDir.appendingPathComponent("catalog.json"))
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: workDir)
    try super.tearDownWithError()
  }

  // MARK: 缺失与损坏

  func testMissingFileLoadsAsFreshEmptyDocument() throws {
    let document = try store.load()

    XCTAssertEqual(document.catalog, ConfigurationCatalog(), "文件缺失按全新安装处理")
    XCTAssertTrue(document.subscriptions.isEmpty, "缺失文件无订阅记录")
  }

  func testBrokenJSONLoadsAsCorrupt() throws {
    try "{ not json {{{".write(to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try store.load()) { error in
      guard
        case CatalogFileStore.PersistenceError.corrupt? = error
          as? CatalogFileStore.PersistenceError
      else {
        return XCTFail("应报 corrupt，实际 \(error)")
      }
    }
  }

  func testUnknownSchemaVersionLoadsAsCorrupt() throws {
    let payload = """
      {"version": 99, "rootChildren": [], "entries": []}
      """
    try payload.write(to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try store.load()) { error in
      XCTAssertEqual(
        error as? CatalogFileStore.PersistenceError, .corrupt(detail: "unsupported version 99"))
    }
  }

  func testDanglingChildReferenceLoadsAsCorrupt() throws {
    let payload = """
      {"version": 1, "rootChildren": ["g1"], "entries": [
        {"id": "g1", "source": "manual", "enabled": true,
         "kind": {"group": {"name": "G", "children": ["ghost"]}}}
      ]}
      """
    try payload.write(to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try store.load()) { error in
      guard
        case CatalogFileStore.PersistenceError.corrupt? = error
          as? CatalogFileStore.PersistenceError
      else {
        return XCTFail("悬空子引用应报 corrupt，实际 \(error)")
      }
    }
  }

  func testDisconnectedCycleLoadsAsCorrupt() throws {
    // 根外孤环：A↔B 互为子节点、不连通根；遍历式检查靠「未到达」发现它
    let payload = """
      {"version": 1, "rootChildren": [], "entries": [
        {"id": "a", "source": "manual", "enabled": true,
         "kind": {"group": {"name": "A", "children": ["b"]}}},
        {"id": "b", "source": "manual", "enabled": true,
         "kind": {"group": {"name": "B", "children": ["a"]}}}
      ]}
      """
    try payload.write(to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try store.load()) { error in
      guard
        case CatalogFileStore.PersistenceError.corrupt? = error
          as? CatalogFileStore.PersistenceError
      else {
        return XCTFail("根外孤环应报 corrupt，实际 \(error)")
      }
    }
  }

  func testReachableCycleLoadsAsCorrupt() throws {
    let payload = """
      {"version": 1, "rootChildren": ["a"], "entries": [
        {"id": "a", "source": "manual", "enabled": true,
         "kind": {"group": {"name": "A", "children": ["b"]}}},
        {"id": "b", "source": "manual", "enabled": true,
         "kind": {"group": {"name": "B", "children": ["a"]}}}
      ]}
      """
    try payload.write(to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try store.load()) { error in
      guard
        case CatalogFileStore.PersistenceError.corrupt? = error
          as? CatalogFileStore.PersistenceError
      else {
        return XCTFail("可达成环应报 corrupt，实际 \(error)")
      }
    }
  }

  // MARK: 往返无损

  func testRoundTripIsLosslessAndKeepsIdentity() throws {
    let original = try Self.makeRichCatalog()

    try store.save(CatalogDocument(catalog: original))
    let loaded = try store.load()

    XCTAssertEqual(loaded.catalog, original, "结构、顺序、启停、字段与订阅夹具全部无损")

    let serverID = NodeID(rawValue: "manual:server")
    let server = try XCTUnwrap(loaded.catalog.entry(for: serverID))
    XCTAssertEqual(server.id, serverID, "身份跨持久化稳定")
    guard case .server(let fields) = server.kind else { return XCTFail("目标应是服务器叶子") }
    XCTAssertEqual(fields.pluginProgram, "v2ray-plugin", "插件程序引用原样保留")
    XCTAssertEqual(fields.pluginOptionsRef, CredentialReference(rawValue: "ref-plugin-options"))
  }

  func testSecondSaveReplacesContent() throws {
    var catalog = ConfigurationCatalog()
    let first = try catalog.addTestServer("first")
    try store.save(CatalogDocument(catalog: catalog))

    try catalog.remove(first)
    let second = try catalog.addTestServer("second")
    try store.save(CatalogDocument(catalog: catalog))

    XCTAssertEqual(try store.load().catalog, catalog)
    XCTAssertFalse(try store.load().catalog.contains(first), "旧内容被整体替换而非追加")
  }

  // MARK: 权限与敏感信息

  func testSaveCreatesDirectory0700AndFile0600() throws {
    var catalog = ConfigurationCatalog()
    _ = try catalog.addTestServer("leaf")

    try store.save(CatalogDocument(catalog: catalog))

    let fileAttributes = try FileManager.default.attributesOfItem(atPath: store.fileURL.path)
    XCTAssertEqual(fileAttributes[.posixPermissions] as? Int, 0o600, "文件权限 0600")
    let dirAttributes = try FileManager.default.attributesOfItem(atPath: workDir.path)
    XCTAssertEqual(dirAttributes[.posixPermissions] as? Int, 0o700, "目录权限 0700")
  }

  func testPersistedFileContainsNoPlaintextSecrets() throws {
    let credentials = InMemoryCredentialStore()
    var catalog = ConfigurationCatalog()
    let passwordRef = CredentialReference.fresh()
    let optionsRef = CredentialReference.fresh()
    let fields = ServerFields(
      address: "203.0.113.7",
      port: 8388,
      encryptionMethod: "aes-256-gcm",
      passwordRef: passwordRef,
      remark: "含插件",
      pluginProgram: "v2ray-plugin",
      pluginOptionsRef: optionsRef
    )
    _ = try catalog.addServer(fields)
    try credentials.save("TOPSECRET-密码", for: passwordRef)
    try credentials.save("obfs-local;obfs=http", for: optionsRef)

    try store.save(CatalogDocument(catalog: catalog))

    let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
    XCTAssertFalse(raw.contains("TOPSECRET-密码"), "密码明文不得进入持久化文件")
    XCTAssertFalse(raw.contains("obfs-local;obfs=http"), "插件参数明文不得进入持久化文件")
    XCTAssertTrue(raw.contains(passwordRef.rawValue), "文件持凭据引用")
    XCTAssertTrue(raw.contains(optionsRef.rawValue))
  }

  /// 富夹具：订阅子树 + 手动组嵌套 + 空组 + 停用节点 + 重排后子序。
  static func makeRichCatalog() throws -> ConfigurationCatalog {
    var catalog = try CatalogFixtures.makeSubscriptionFixture(prefix: "sub9").catalog
    let group = NodeID(rawValue: "manual:group")
    try catalog.addGroup("手动组", id: group)
    let server = NodeID(rawValue: "manual:server")
    try catalog.addServer(
      ServerFields(
        address: "198.51.100.5",
        port: 443,
        encryptionMethod: "chacha20-ietf-poly1305",
        passwordRef: CredentialReference(rawValue: "ref-password"),
        remark: "带插件",
        pluginProgram: "v2ray-plugin",
        pluginOptionsRef: CredentialReference(rawValue: "ref-plugin-options")
      ),
      id: server,
      to: group
    )
    let disabled = try catalog.addTestServer("停用", to: group)
    try catalog.setEnabled(disabled, false)
    try catalog.addGroup("空组", id: NodeID(rawValue: "manual:empty"))
    try catalog.move(server, to: group, index: 0)
    return catalog
  }

  // MARK: 订阅记录文档（v2，issue #35）

  func testSubscriptionRecordRoundTripsWithStatus() throws {
    let catalog = try CatalogFixtures.makeSubscriptionFixture(prefix: "sub2").catalog
    let record = SubscriptionRecord(
      id: NodeID(rawValue: "sub2:source"),
      groupID: NodeID(rawValue: "sub2:group"),
      urlRef: CredentialReference(rawValue: "ref-sub-url"),
      status: .failed(at: Date(timeIntervalSince1970: 1_789_000_000), reason: "HTTP 503"))

    try store.save(CatalogDocument(catalog: catalog, subscriptions: [record]))
    let loaded = try store.load()

    XCTAssertEqual(loaded.subscriptions, [record], "订阅记录与刷新状态无损")
    XCTAssertEqual(loaded.catalog, catalog)
    XCTAssertFalse(
      try String(contentsOf: store.fileURL, encoding: .utf8).contains("https://"),
      "订阅 URL 明文不得落盘（D5：只存凭据引用）")
  }

  func testV1PayloadLoadsWithEmptySubscriptions() throws {
    let payload = """
      {"version": 1, "rootChildren": [], "entries": []}
      """
    try payload.write(to: store.fileURL, atomically: true, encoding: .utf8)

    let loaded = try store.load()

    XCTAssertTrue(loaded.subscriptions.isEmpty, "v1 文档无订阅记录")
    XCTAssertTrue(loaded.catalog.isEmpty)
  }

  /// 订阅记录 JSON 用真编码器生成：枚举 Codable 形状是实现细节，不在测试里手写。
  private func subscriptionJSON(
    id: String, groupID: String, urlRef: String = "ref-sub-url"
  ) throws -> String {
    let record = SubscriptionRecord(
      id: NodeID(rawValue: id),
      groupID: NodeID(rawValue: groupID),
      urlRef: CredentialReference(rawValue: urlRef),
      status: .never)
    return String(data: try JSONEncoder().encode(record), encoding: .utf8)!
  }

  func testSubscriptionGroupMissingLoadsAsCorrupt() throws {
    let recordJSON = try subscriptionJSON(id: "sub-x", groupID: "ghost")
    let payload =
      """
      {"version": 2, "rootChildren": [], "entries": [], "subscriptions": [\(recordJSON)]}
      """
    try payload.write(to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try store.load()) { error in
      guard
        case CatalogFileStore.PersistenceError.corrupt? = error
          as? CatalogFileStore.PersistenceError
      else {
        return XCTFail("固定分组缺失应报 corrupt，实际 \(error)")
      }
    }
  }

  func testDuplicateSubscriptionIDLoadsAsCorrupt() throws {
    let first = try subscriptionJSON(id: "sub-x", groupID: "g1", urlRef: "ref-u")
    let second = try subscriptionJSON(id: "sub-x", groupID: "g1", urlRef: "ref-v")
    let payload =
      """
      {"version": 2, "rootChildren": [], "entries": [], "subscriptions": [\(first), \(second)]}
      """
    try payload.write(to: store.fileURL, atomically: true, encoding: .utf8)

    XCTAssertThrowsError(try store.load()) { error in
      guard
        case CatalogFileStore.PersistenceError.corrupt? = error
          as? CatalogFileStore.PersistenceError
      else {
        return XCTFail("重复订阅身份应报 corrupt，实际 \(error)")
      }
    }
  }
}
