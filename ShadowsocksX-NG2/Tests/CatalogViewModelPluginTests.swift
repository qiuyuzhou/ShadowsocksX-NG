import XCTest

@testable import ShadowsocksX_NG2

/// 插件区编辑语义（issue #38，D10）：选择器三态呈现与落盘、「无」整体清除、
/// 参数写删钥匙串、集外引用原样保留，以及经编辑面的 ss:// 分享往返。
/// 走内存凭据存储与注入 bundleURL 的受管插件提供。
@MainActor
final class CatalogViewModelPluginTests: XCTestCase {
  private var workDir: URL!
  private var bundleRoot: URL!
  private var fileURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var viewModel: CatalogViewModel!

  override func setUp() async throws {
    try await super.setUp()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("catalog-plugin-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    bundleRoot = FileManager.default.temporaryDirectory
      .appendingPathComponent("catalog-plugin-bundle-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
      at: bundleRoot.appendingPathComponent("Contents/Helpers/Plugins"),
      withIntermediateDirectories: true)
    fileURL = workDir.appendingPathComponent("catalog.json")
    credentials = InMemoryCredentialStore()
    viewModel = makeViewModel()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: workDir)
    try? FileManager.default.removeItem(at: bundleRoot)
    try await super.tearDown()
  }

  private var pluginBinaryName: String { ManagedPluginCatalog.plugins[0].program }

  private func writePluginBinary() throws {
    let url = bundleRoot.appendingPathComponent("Contents/Helpers/Plugins/\(pluginBinaryName)")
    try Data("#!/bin/sh\n".utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
  }

  private func makeViewModel() -> CatalogViewModel {
    let model = CatalogViewModel(
      fileStore: CatalogFileStore(fileURL: fileURL),
      credentials: credentials,
      plugins: BundleManagedPluginProvider(bundleURL: bundleRoot))
    model.postCommit = {}
    return model
  }

  /// 直建目录（不经 URI 导入）后重载视图模型，返回该服务器身份。
  private func addPluginServer(program: String?, options: String?) async throws -> NodeID {
    var catalog = ConfigurationCatalog()
    var fields = ServerFields(
      address: "203.0.113.7",
      port: 8388,
      encryptionMethod: "aes-256-gcm",
      passwordRef: CredentialReference(rawValue: "ref-pw"),
      remark: "带插件")
    try credentials.save("pw", for: fields.passwordRef)
    if let program {
      fields.pluginProgram = program
      if let options {
        let reference = CredentialReference(rawValue: "ref-opts")
        try credentials.save(options, for: reference)
        fields.pluginOptionsRef = reference
      }
    }
    try catalog.addServer(fields)
    try CatalogFileStore(fileURL: fileURL).save(CatalogDocument(catalog: catalog))
    viewModel = makeViewModel()
    return try XCTUnwrap(viewModel.catalog.rootChildren.first)
  }

  private func serverFields(of id: NodeID) -> ServerFields? {
    guard case .server(let fields) = viewModel.entry(for: id)?.kind else { return nil }
    return fields
  }

  private func update(
    _ id: NodeID,
    plugin: PluginSelection,
    pluginOptions: String?,
    address: String = "203.0.113.7"
  ) async throws {
    try await viewModel.updateServer(
      id, address: address, port: 8388, encryptionMethod: "aes-256-gcm",
      password: "pw", remark: "带插件", plugin: plugin, pluginOptions: pluginOptions)
  }

  // MARK: - 选择器呈现

  func testManagedSelectionShownWithFactsAndParamsPlaintext() async throws {
    try writePluginBinary()
    let id = try await addPluginServer(program: pluginBinaryName, options: "mode=websocket")
    let plugin = try XCTUnwrap(viewModel.serverFormState(for: id)?.plugin)
    XCTAssertEqual(plugin.selection, .managed(program: pluginBinaryName))
    XCTAssertTrue(plugin.provided, "二进制在位即提供")
    XCTAssertTrue(plugin.optionsPresent)
    XCTAssertEqual(plugin.options, "mode=websocket", "参数明文供输入框预填")
    XCTAssertEqual(plugin.managed.map(\.program), [pluginBinaryName])
  }

  func testMissingBinaryShowsManagedButNotProvided() async throws {
    let id = try await addPluginServer(program: pluginBinaryName, options: nil)
    let plugin = try XCTUnwrap(viewModel.serverFormState(for: id)?.plugin)
    XCTAssertEqual(plugin.selection, .managed(program: pluginBinaryName))
    XCTAssertFalse(plugin.provided, "打包损坏/降级丢插件时点名呈现")
  }

  func testUnknownProgramRendersExplicitUnknownState() async throws {
    let id = try await addPluginServer(program: "obfs-local", options: "obfs=http")
    let plugin = try XCTUnwrap(viewModel.serverFormState(for: id)?.plugin)
    XCTAssertEqual(plugin.selection, .unknown(program: "obfs-local"), "集外引用显式未提供")
    XCTAssertFalse(plugin.provided)
    XCTAssertTrue(plugin.optionsPresent, "已配置参数的事实照常呈现")
    XCTAssertEqual(plugin.options, "", "集外引用不解析参数明文")
  }

  func testNoPluginSelectionIsDefault() async throws {
    let id = try await addPluginServer(program: nil, options: nil)
    let plugin = try XCTUnwrap(viewModel.serverFormState(for: id)?.plugin)
    XCTAssertEqual(plugin.selection, .none)
    XCTAssertFalse(plugin.provided)
    XCTAssertFalse(plugin.optionsPresent)
  }

  // MARK: - 落盘语义

  func testSelectingManagedPluginSavesProgramAndOptions() async throws {
    try writePluginBinary()
    let id = try await addPluginServer(program: nil, options: nil)
    try await update(
      id, plugin: .managed(program: pluginBinaryName),
      pluginOptions: "mode=websocket;host=example.com")
    let fields = try XCTUnwrap(serverFields(of: id))
    XCTAssertEqual(fields.pluginProgram, pluginBinaryName)
    let optionsRef = try XCTUnwrap(fields.pluginOptionsRef)
    XCTAssertEqual(try credentials.secret(for: optionsRef), "mode=websocket;host=example.com")
  }

  func testSavingEmptyOptionsDropsOptionsReference() async throws {
    try writePluginBinary()
    let id = try await addPluginServer(program: pluginBinaryName, options: "mode=websocket")
    let oldRef = try XCTUnwrap(serverFields(of: id)?.pluginOptionsRef)
    try await update(id, plugin: .managed(program: pluginBinaryName), pluginOptions: "   ")
    let fields = try XCTUnwrap(serverFields(of: id))
    XCTAssertEqual(fields.pluginProgram, pluginBinaryName, "程序引用保留")
    XCTAssertNil(fields.pluginOptionsRef, "空参数即无参数引用")
    XCTAssertNil(try credentials.secret(for: oldRef), "清空参数即删除钥匙串秘密")
  }

  func testSelectingNoneClearsProgramAndOptions() async throws {
    let id = try await addPluginServer(program: pluginBinaryName, options: "mode=websocket")
    let oldRef = try XCTUnwrap(serverFields(of: id)?.pluginOptionsRef)
    try await update(id, plugin: .none, pluginOptions: nil)
    let fields = try XCTUnwrap(serverFields(of: id))
    XCTAssertNil(fields.pluginProgram)
    XCTAssertNil(fields.pluginOptionsRef)
    XCTAssertNil(try credentials.secret(for: oldRef))
  }

  func testUnknownSelectionPreservesReferenceAndOptionsVerbatim() async throws {
    let id = try await addPluginServer(program: "obfs-local", options: "obfs=http")
    let before = try XCTUnwrap(serverFields(of: id))
    try await update(
      id, plugin: .unknown(program: "obfs-local"), pluginOptions: nil,
      address: "198.51.100.9")
    let after = try XCTUnwrap(serverFields(of: id))
    XCTAssertEqual(after.address, "198.51.100.9", "连接字段照常更新")
    XCTAssertEqual(after.pluginProgram, "obfs-local", "集外引用原样保留")
    XCTAssertEqual(after.pluginOptionsRef, before.pluginOptionsRef)
    let ref = try XCTUnwrap(after.pluginOptionsRef)
    XCTAssertEqual(try credentials.secret(for: ref), "obfs=http", "参数秘密不动")
  }

  func testForgedUnmanagedSelectionIsRejected() async throws {
    let id = try await addPluginServer(program: nil, options: nil)
    await expectThrowsAsync(
      {
        try await update(id, plugin: .managed(program: "obfs-local"), pluginOptions: nil)
      },
      onThrow: { error in
        XCTAssertEqual(error as? ServerFormError, .pluginNotManaged("obfs-local"))
      })
  }

  // MARK: - 分享往返（与 #32 编解码一致）

  func testSharedSsUriRoundTripsThroughEditorEdit() async throws {
    try writePluginBinary()
    let id = try await addPluginServer(program: nil, options: nil)
    try await update(
      id, plugin: .managed(program: pluginBinaryName),
      pluginOptions: "mode=websocket;host=example.com")

    let shared = try viewModel.ssUri(for: id)
    let decoded = try SsUri.decode(shared)
    XCTAssertEqual(decoded.pluginProgram, pluginBinaryName)
    XCTAssertEqual(decoded.pluginOptions, "mode=websocket;host=example.com")

    // 导回目录：插件字段同构（新建身份，不按内容去重）。
    let outcome = try await viewModel.addServers(fromURIs: shared, into: nil)
    XCTAssertEqual(outcome.added, 1)
    let importedID = try XCTUnwrap(
      viewModel.catalog.rootChildren.dropFirst().first,
      "第二个根节点应是新导入的服务器")
    let imported = try XCTUnwrap(serverFields(of: importedID))
    XCTAssertEqual(imported.pluginProgram, pluginBinaryName)
    let importedRef = try XCTUnwrap(imported.pluginOptionsRef)
    XCTAssertEqual(
      try credentials.secret(for: importedRef), "mode=websocket;host=example.com")
  }
}
