import XCTest

@testable import ShadowsocksX_NG2

/// 运行时文件存取（spec #21 D5，issue #27）：0700/0600 权限基线、原子替换、
/// 读取侧判定与显式停止清理。
final class RuntimeFileStoreTests: XCTestCase {
  private var runtime: ProxyRuntimeFixture.TemporaryRuntime!
  private var store: RuntimeFileStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    runtime = ProxyRuntimeFixture.makeTemporaryRuntime()
    store = RuntimeFileStore(fileURL: runtime.contract)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: runtime.directory)
    try super.tearDownWithError()
  }

  private func permissions(of url: URL) throws -> Int {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    return try XCTUnwrap(attributes[.posixPermissions] as? Int)
  }

  // MARK: 权限基线（D5）

  func testWriteCreatesDirectoryWith0700AndFileWith0600() throws {
    try store.write(ProxyRuntimeFixture.makeDocument())

    XCTAssertEqual(try permissions(of: runtime.directory), 0o700, "runtime/ 目录 0700")
    XCTAssertEqual(try permissions(of: runtime.contract), 0o600, "契约文件 0600")
  }

  func testWriteHealsDirectoryPermissionBaseline() throws {
    try FileManager.default.createDirectory(
      at: runtime.directory, withIntermediateDirectories: true)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: runtime.directory.path)

    try store.write(ProxyRuntimeFixture.makeDocument())

    XCTAssertEqual(try permissions(of: runtime.directory), 0o700, "目录权限自愈回 0700")
  }

  func testAtomicReplaceKeepsFileAt0600() throws {
    try store.write(ProxyRuntimeFixture.makeDocument(localPort: 1086))

    try store.write(ProxyRuntimeFixture.makeDocument(localPort: 2086))

    XCTAssertEqual(try permissions(of: runtime.contract), 0o600, "替换后仍 0600")
    let document = try XCTUnwrap(store.loadDocument())
    XCTAssertEqual(document.socksPort, 2086, "内容已被原子替换")
  }

  func testWriteLeavesNoTemporaryFilesBehind() throws {
    try store.write(ProxyRuntimeFixture.makeDocument())
    try store.write(ProxyRuntimeFixture.makeDocument(localPort: 2087))

    let residue = try FileManager.default.contentsOfDirectory(atPath: runtime.directory.path)
      .filter { $0.hasPrefix(".sslocal-active.json.tmp-") }
    XCTAssertTrue(residue.isEmpty, "临时文件不应残留，实际 \(residue)")
  }

  func testACLAndContractAreWrittenWithProtectedPermissions() throws {
    let document = SslocalRuntimeDocument(
      servers: [],
      listen: SslocalListenSettings(),
      acl: .direct(at: store.aclFileURL))

    try store.write(document)

    XCTAssertEqual(try permissions(of: runtime.directory), 0o700)
    XCTAssertEqual(try permissions(of: runtime.contract), 0o600)
    XCTAssertEqual(try permissions(of: store.aclFileURL), 0o600)
    XCTAssertEqual(try store.loadDocument(), document)
  }

  func testACLSidecarMismatchRejectsTheRuntimeDocument() throws {
    let document = SslocalRuntimeDocument(
      servers: [],
      listen: SslocalListenSettings(),
      acl: .direct(at: store.aclFileURL))
    try store.write(document)
    try Data("[proxy_all]\n".utf8).write(to: store.aclFileURL)

    XCTAssertNil(store.loadDocument(), "wrapper 与 GUI 都拒绝摘要不符的 ACL sidecar")
  }

  func testContractWriteFailureRestoresPreviousACLSidecar() throws {
    let contractURL = runtime.contract
    let failingStore = RuntimeFileStore(fileURL: contractURL) { data, url in
      guard url != contractURL else { throw NSError(domain: "test", code: 1) }
      try AtomicFileWriter.write(data, to: url)
    }
    let previousACL = ProxyACLDocument(
      path: failingStore.aclFileURL.standardizedFileURL.path,
      summary: "previous",
      content: "[bypass_all]\n# previous\n")
    try Data(previousACL.content.utf8).write(to: failingStore.aclFileURL)
    let document = SslocalRuntimeDocument(
      servers: [],
      listen: SslocalListenSettings(),
      acl: ProxyACLDocument(
        path: failingStore.aclFileURL.standardizedFileURL.path,
        summary: "next",
        content: "[bypass_all]\n# next\n"))

    XCTAssertThrowsError(try failingStore.write(document))
    XCTAssertTrue(
      try Data(contentsOf: failingStore.aclFileURL) == Data(previousACL.content.utf8),
      "运行时契约写失败后恢复此前的 ACL sidecar")
  }

  // MARK: 读取侧判定

  func testLoadDocumentRoundTripsWrittenDocument() throws {
    let document = ProxyRuntimeFixture.makeDocument()
    try store.write(document)

    XCTAssertEqual(try store.loadDocument(), document)
    XCTAssertEqual(try store.readData(), try document.jsonData())
  }

  func testLoadDocumentReturnsNilForMissingFile() throws {
    XCTAssertNil(try store.loadDocument())
    XCTAssertNil(try store.readData())
  }

  func testLoadDocumentReturnsNilForCorruptJSON() throws {
    try Data("not json {".utf8).write(to: runtime.contract)

    XCTAssertNil(try store.loadDocument())
  }

  func testLoadDocumentReturnsNilForStructurallyInvalidDocument() throws {
    try store.write(
      SslocalRuntimeDocument(
        servers: [], listen: SslocalListenSettings(pacPort: 0)))

    XCTAssertNil(try store.loadDocument(), "PAC 端口无效属结构性无效（读取侧防御）")
  }

  // MARK: 显式停止清理

  func testDeleteRuntimeFilesRemovesContractPidAndStaleTemporaries() throws {
    try store.write(
      SslocalRuntimeDocument(
        servers: [], listen: SslocalListenSettings(), acl: .direct(at: store.aclFileURL)))
    try Data("1086".utf8).write(to: runtime.pidFile)
    try Data("status".utf8).write(to: store.runtimeStatusFileURL)
    let staleTemporary = runtime.directory.appendingPathComponent(".sslocal-active.json.tmp-stale")
    try Data("partial".utf8).write(to: staleTemporary)

    store.deleteRuntimeFiles()

    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.contract.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: runtime.pidFile.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.aclFileURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.runtimeStatusFileURL.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staleTemporary.path))
  }

  func testDeleteRuntimeFilesIsHarmlessWhenNothingExists() throws {
    store.deleteRuntimeFiles()
    store.deleteRuntimeFiles()
    XCTAssertTrue(true, "重复清理不抛错")
  }

  // MARK: 文档校验与监听指纹

  func testWellFormedValidationRejectsStructuralGarbage() {
    func document(
      localPort: Int = 1086,
      pacPort: Int = 1089,
      servers: [SslocalServerDocument]
    ) -> SslocalRuntimeDocument {
      SslocalRuntimeDocument(
        servers: servers,
        listen: SslocalListenSettings(
          socksPort: localPort, pacPort: pacPort))
    }
    func server(
      id: String = "s", address: String = "203.0.113.7", port: Int = 8388,
      method: String = "aes-256-gcm"
    ) -> SslocalServerDocument {
      SslocalServerDocument(
        id: id, remarks: "", server: address, serverPort: port, password: "pw",
        method: method, plugin: nil, pluginOpts: nil)
    }

    XCTAssertTrue(document(servers: [server()]).isWellFormed)
    XCTAssertTrue(
      document(servers: []).isWellFormed,
      "空 servers 合法：无活动目标的本地监听（issue #60）")
    XCTAssertFalse(document(pacPort: 0, servers: [server()]).isWellFormed)
    XCTAssertFalse(document(localPort: 0, servers: [server()]).isWellFormed)
    XCTAssertFalse(document(localPort: 65_536, servers: [server()]).isWellFormed)
    XCTAssertFalse(document(servers: [server(port: 0)]).isWellFormed)
    XCTAssertFalse(document(servers: [server(address: "")]).isWellFormed)
    XCTAssertFalse(document(servers: [server(method: "")]).isWellFormed)
    XCTAssertFalse(document(servers: [server(id: "")]).isWellFormed)
  }

  func testListenFingerprintIgnoresServerChangesAndTracksListenFields() {
    let base = ProxyRuntimeFixture.makeDocument()
    let serverChanged = ProxyRuntimeFixture.makeDocument(serverAddress: "198.51.100.9")
    let listenChanged = ProxyRuntimeFixture.makeDocument(localPort: 2088)

    XCTAssertEqual(
      base.listenFingerprint, serverChanged.listenFingerprint,
      "仅服务器列表变化不影响监听指纹（走 SIGUSR1 热重载）")
    XCTAssertNotEqual(
      base.listenFingerprint, listenChanged.listenFingerprint,
      "监听端口变化改变指纹（走优雅重启）")
  }

  func testValidatedRuntimeRequiresFixedTCPAndUDPModeForSOCKS() throws {
    let base = ProxyRuntimeFixture.makeDocument()
    var object = try XCTUnwrap(
      try JSONSerialization.jsonObject(with: base.jsonData()) as? [String: Any])
    var locals = try XCTUnwrap(object["locals"] as? [[String: Any]])
    locals[0]["mode"] = "tcp_only"
    object["locals"] = locals
    let data = try JSONSerialization.data(withJSONObject: object)

    XCTAssertNil(SslocalRuntimeDocument.decodeValidated(data))
  }
}
