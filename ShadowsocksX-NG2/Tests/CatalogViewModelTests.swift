import XCTest

@testable import ShadowsocksX_NG2

/// 主窗口视图模型（issue #32）：三入口导入、凭据生命周期、订阅子树只读夹具、
/// 分享互逆与提交接线。全部走内存凭据存储与临时目录文件存储；提交后的运行
/// 时收敛以确定性 fake 计数（issue #40）。
@MainActor
final class CatalogViewModelTests: XCTestCase {
  private var workDir: URL!
  private var fileURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var runtime: FakeCatalogRuntime!
  private var viewModel: CatalogViewModel!

  override func setUp() async throws {
    try await super.setUp()
    // 专用工作目录：写入器会把父目录强制 0700（不得指向临时根）。
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("catalog-vm-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    fileURL = workDir.appendingPathComponent("catalog.json")
    credentials = InMemoryCredentialStore()
    runtime = FakeCatalogRuntime()
    viewModel = makeViewModel()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: workDir)
    try await super.tearDown()
  }

  private func makeViewModel() -> CatalogViewModel {
    // 计数即提交计数：提交后的运行时收敛由协调器异步调度（issue #40）。
    runtime.hasActiveTarget = true
    let coordinator = CatalogCommitCoordinator(
      fileStore: CatalogFileStore(fileURL: fileURL), runtime: runtime)
    return CatalogViewModel(
      coordinator: coordinator,
      credentials: credentials,
      plugins: NoManagedPluginProvider())
  }

  private func makeSubscriptionCatalog() throws {
    let fixture = try CatalogFixtures.makeSubscriptionFixture()
    try CatalogFileStore(fileURL: fileURL).save(CatalogDocument(catalog: fixture.catalog))
    viewModel = makeViewModel()
  }

  private func serverFields(of id: NodeID) -> ServerFields? {
    guard case .server(let fields) = viewModel.entry(for: id)?.kind else { return nil }
    return fields
  }

  // MARK: - 三入口导入（共同落点）

  func testImportMixedLinesAddsParsedAndReportsFailures() async throws {
    let validSIP002 = "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQxMjM@203.0.113.7:8388#香港 01"
    let legacy =
      "ss://YWVzLTI1Ni1nY206dGVzdEAyMDMuMC4xMTMuNzo4Mzg4"
    let outcome = try await viewModel.addServers(
      fromURIs: "\(validSIP002)\n垃圾行\n\(legacy)", into: nil)
    XCTAssertEqual(outcome.added, 2)
    XCTAssertEqual(outcome.failures.count, 1)

    let roots = viewModel.catalog.rootChildren
    XCTAssertEqual(roots.count, 2)
    guard case .server(let first) = viewModel.entry(for: roots[0])?.kind else {
      return XCTFail("首个导入应为服务器叶子")
    }
    XCTAssertEqual(first.remark, "香港 01")
    let secret = try credentials.secret(for: first.passwordRef)
    XCTAssertEqual(secret, "password123")
    // 两个身份均为全新 UUID 形态（不按内容去重）。
    XCTAssertNotEqual(roots[0], roots[1])
  }

  func testImportWithPluginStoresProgramAndOptionsRef() async throws {
    let uri =
      "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQxMjM@203.0.113.7:8388"
      + "/?plugin=v2ray-plugin%3Bmode%3Dwebsocket%3Bhost%3Dexample.com"
    _ = try await viewModel.addServers(fromURIs: uri, into: nil)
    guard
      case .server(let fields) = viewModel.entry(for: viewModel.catalog.rootChildren[0])?
        .kind
    else { return XCTFail("应为服务器叶子") }
    XCTAssertEqual(fields.pluginProgram, "v2ray-plugin")
    let optionsRef = try XCTUnwrap(fields.pluginOptionsRef)
    XCTAssertEqual(try credentials.secret(for: optionsRef), "mode=websocket;host=example.com")
  }

  func testImportUnsupportedMethodKeepsServerAsInvalidCandidate() async throws {
    let uri = SsUri(
      method: "future-cipher", password: "password", host: "203.0.113.7", port: 8388
    ).encode()

    let outcome = try await viewModel.addServers(fromURIs: uri, into: nil)

    XCTAssertEqual(outcome.added, 1)
    let id = try XCTUnwrap(viewModel.catalog.rootChildren.first)
    XCTAssertEqual(
      viewModel.validation(for: id)?.issues,
      [.unsupportedEncryptionMethod("future-cipher")])
  }

  func testImportIntoSelectedManualGroup() async throws {
    let groupID = try await viewModel.addGroup(named: "手动组", into: nil)
    let target = try XCTUnwrap(viewModel.importTargetParent(for: groupID))
    XCTAssertEqual(target, groupID)
    _ = try await viewModel.addServers(
      fromURIs: "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQxMjM@203.0.113.7:8388", into: target)
    XCTAssertEqual(try viewModel.catalog.children(of: groupID).count, 1)
    // 选中服务器时落到其手动父组；无选中落到根。
    let serverID = try XCTUnwrap(try viewModel.catalog.children(of: groupID).first)
    XCTAssertEqual(viewModel.importTargetParent(for: serverID), groupID)
    XCTAssertNil(viewModel.importTargetParent(for: nil))
  }

  func testImportTargetSkipsSubscriptionSubtree() async throws {
    try makeSubscriptionCatalog()
    let fixture = try CatalogFixtures.makeSubscriptionFixture()
    XCTAssertEqual(viewModel.importTargetParent(for: fixture.groupID), nil)
    XCTAssertEqual(viewModel.importTargetParent(for: fixture.serverIDs[0]), nil)
  }

  // MARK: - 表单编辑与凭据生命周期

  func testUpdateServerPersistsFieldsAndPassword() async throws {
    _ = try await viewModel.addServers(
      fromURIs: "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQxMjM@203.0.113.7:8388", into: nil)
    let id = try XCTUnwrap(viewModel.catalog.rootChildren.first)
    let oldRef = try XCTUnwrap(serverFields(of: id)?.passwordRef)
    try await viewModel.updateServer(
      id, address: "198.51.100.9", port: 9999, encryptionMethod: "chacha20-ietf-poly1305",
      password: "新密码", remark: "改过的", plugin: .none, pluginOptions: nil)
    let fields = try XCTUnwrap(serverFields(of: id))
    XCTAssertEqual(fields.address, "198.51.100.9")
    XCTAssertEqual(fields.port, 9999)
    XCTAssertEqual(fields.remark, "改过的")
    XCTAssertEqual(fields.passwordRef, oldRef, "同一引用始终对应最新秘密")
    XCTAssertEqual(try credentials.secret(for: oldRef), "新密码")
    // 连续提交合并为最新代次的收敛（issue #40）：旧代次在启动前被取代，
    // 最终结果必为最新提交快照。
    await waitUntilRuntimeSettles(viewModel.coordinator.syncStatus != .syncing(generation: 2))
    XCTAssertEqual(
      viewModel.coordinator.syncStatus,
      .finished(generation: 2, outcome: .converged(skippedServers: [])))
    XCTAssertFalse(runtime.convergeSnapshots.isEmpty)
    XCTAssertEqual(runtime.convergeSnapshots.last?.catalog, viewModel.catalog)
  }

  func testUpdateServerRejectsInvalidAddressAndPort() async throws {
    _ = try await viewModel.addServers(
      fromURIs: "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQxMjM@203.0.113.7:8388", into: nil)
    let id = try XCTUnwrap(viewModel.catalog.rootChildren.first)
    await expectThrowsAsync(
      {
        try await viewModel.updateServer(
          id, address: "  ", port: 8388, encryptionMethod: "aes-256-gcm", password: "p",
          remark: "", plugin: .none, pluginOptions: nil)
      },
      onThrow: { error in
        XCTAssertEqual(error as? ServerFormError, .invalidAddress)
      })
    await expectThrowsAsync(
      {
        try await viewModel.updateServer(
          id, address: "203.0.113.7", port: 0, encryptionMethod: "aes-256-gcm", password: "p",
          remark: "", plugin: .none, pluginOptions: nil)
      },
      onThrow: { error in
        XCTAssertEqual(error as? ServerFormError, .invalidPort)
      })
  }

  func testRemoveServerCleansCredentialsAndClearsSelection() async throws {
    _ = try await viewModel.addServers(
      fromURIs: "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQxMjM@203.0.113.7:8388"
        + "/?plugin=v2ray-plugin%3Bmode%3Dwebsocket", into: nil)
    let id = try XCTUnwrap(viewModel.catalog.rootChildren.first)
    let refs = serverFields(of: id).map { ($0.passwordRef, $0.pluginOptionsRef) }
    let (passwordRef, optionsRef) = try XCTUnwrap(refs)
    viewModel.selectedNodeID = id
    try await viewModel.remove(id)
    XCTAssertFalse(viewModel.catalog.contains(id))
    XCTAssertNil(viewModel.selectedNodeID, "删除选中节点后清除选中")
    XCTAssertNil(try credentials.secret(for: passwordRef), "密码秘密已清理")
    XCTAssertEqual(try credentials.secret(for: try XCTUnwrap(optionsRef)), nil, "插件参数秘密已清理")
  }

  func testRemoveNonEmptyGroupRemovesWholeSubtree() async throws {
    let groupID = try await viewModel.addGroup(named: "组", into: nil)
    _ = try await viewModel.addServers(
      fromURIs: "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQxMjM@203.0.113.7:8388", into: groupID)
    let serverID = try XCTUnwrap(try viewModel.catalog.children(of: groupID).first)
    try await viewModel.remove(groupID)
    XCTAssertFalse(viewModel.catalog.contains(groupID))
    XCTAssertFalse(viewModel.catalog.contains(serverID))
    XCTAssertTrue(viewModel.catalog.isEmpty)
  }

  // MARK: - 订阅子树只读（夹具验证：结构操作被拒）

  func testSubscriptionStructureOperationsRejected() async throws {
    try makeSubscriptionCatalog()
    let fixture = try CatalogFixtures.makeSubscriptionFixture()
    let subscriptionServer = fixture.serverIDs[0]
    let manualGroupID = try await viewModel.addGroup(named: "手动组", into: nil)

    await expectThrowsAsync { try await viewModel.move(subscriptionServer, to: manualGroupID) }
    await expectThrowsAsync { try await viewModel.remove(subscriptionServer) }
    await expectThrowsAsync { try await viewModel.renameGroup(fixture.groupID, to: "改名") }
    await expectThrowsAsync {
      try await viewModel.updateServer(
        subscriptionServer, address: "0.0.0.0", port: 1, encryptionMethod: "x", password: "p",
        remark: "", plugin: .none, pluginOptions: nil)
    }
    // 手动节点移进订阅子树同样被拒（跨来源）。
    await expectThrowsAsync { try await viewModel.move(manualGroupID, to: fixture.groupID) }
  }

  // MARK: - 分享（与添加互逆）

  func testShareSsUriRoundTripsBackThroughImport() async throws {
    let source =
      "ss://YWVzLTI1Ni1nY206cGFzc3dvcmQxMjM@203.0.113.7:8388"
      + "/?plugin=v2ray-plugin%3Bmode%3Dwebsocket%3Bhost%3Dexample.com#分享节点"
    _ = try await viewModel.addServers(fromURIs: source, into: nil)
    let id = try XCTUnwrap(viewModel.catalog.rootChildren.first)
    let shared = try viewModel.ssUri(for: id)
    let decoded = try SsUri.decode(shared)
    XCTAssertEqual(decoded.method, "aes-256-gcm")
    XCTAssertEqual(decoded.password, "password123")
    XCTAssertEqual(decoded.host, "203.0.113.7")
    XCTAssertEqual(decoded.port, 8388)
    XCTAssertEqual(decoded.pluginProgram, "v2ray-plugin")
    XCTAssertEqual(decoded.pluginOptions, "mode=websocket;host=example.com")
    XCTAssertEqual(decoded.remark, "分享节点")
  }

  func testShareFailsWhenCredentialMissing() async throws {
    var catalog = ConfigurationCatalog()
    var fields = CatalogFixtures.serverFields(remark: "无凭据")
    fields.passwordRef = CredentialReference.fresh()
    try catalog.addServer(fields)
    try CatalogFileStore(fileURL: fileURL).save(CatalogDocument(catalog: catalog))
    viewModel = makeViewModel()
    let id = try XCTUnwrap(viewModel.catalog.rootChildren.first)
    await expectThrowsAsync { try viewModel.ssUri(for: id) }
  }

  // MARK: - 持久化

  func testChangesPersistAcrossViewModelInstances() async throws {
    let groupID = try await viewModel.addGroup(named: "持久组", into: nil)
    let reloaded = makeViewModel()
    XCTAssertTrue(reloaded.catalog.contains(groupID))
    XCTAssertEqual(reloaded.displayName(for: groupID), "持久组")
  }
}

/// `XCTAssertThrowsError` 的 async 版本（表达式在 await 之后才能检查）。
func expectThrowsAsync(
  _ expression: () async throws -> Void,
  onThrow errorHandler: (Error) -> Void = { _ in },
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  do {
    _ = try await expression()
    XCTFail("预期抛错，但成功返回", file: file, line: line)
  } catch {
    errorHandler(error)
  }
}
