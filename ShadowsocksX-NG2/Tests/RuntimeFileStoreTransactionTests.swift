import XCTest

@testable import ShadowsocksX_NG2

/// ACL 部署事务通过临时目录与原子写入故障 seam 验证。
final class RuntimeFileStoreTransactionTests: XCTestCase {
  private var runtime: ProxyRuntimeFixture.TemporaryRuntime!
  private var store: RuntimeFileStore!

  override func setUpWithError() throws {
    runtime = ProxyRuntimeFixture.makeTemporaryRuntime()
    store = RuntimeFileStore(fileURL: runtime.contract)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: runtime.directory)
  }

  func testDecodedDocumentContractFailurePreservesExistingVariant() throws {
    let original = SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(), acl: .direct(at: store.aclFileURL))
    try store.write(original)
    let decoded = try XCTUnwrap(store.loadDocument())
    let variant = store.aclVariantFileURL(summary: "direct")
    let bytes = try Data(contentsOf: variant)
    let failing = RuntimeFileStore(fileURL: runtime.contract) { _, _ in
      throw NSError(domain: "contract", code: 1)
    }
    XCTAssertThrowsError(try failing.write(decoded))
    XCTAssertEqual(try Data(contentsOf: variant), bytes)
    XCTAssertEqual(store.loadDocument(), original)
  }

  func testUnchangedACLFailureDoesNotRewriteVariantOrLink() throws {
    let document = SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(), acl: .direct(at: store.aclFileURL))
    try store.write(document)
    let variant = store.aclVariantFileURL(summary: "direct")
    let bytes = try Data(contentsOf: variant)
    let linkNumber =
      try FileManager.default.attributesOfItem(atPath: store.aclFileURL.path)[.systemFileNumber]
      as? NSNumber
    var touched: [URL] = []
    let failing = RuntimeFileStore(fileURL: runtime.contract) { _, url in
      touched.append(url)
      throw NSError(domain: "contract", code: 1)
    }
    XCTAssertThrowsError(try failing.write(document))
    XCTAssertEqual(touched, [runtime.contract])
    XCTAssertEqual(try Data(contentsOf: variant), bytes)
    XCTAssertEqual(
      try FileManager.default.attributesOfItem(atPath: store.aclFileURL.path)[.systemFileNumber]
        as? NSNumber, linkNumber)
  }

  func testLinkRestoreFailureStillRestoresVariant() throws {
    let old = SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(), acl: .global(at: store.aclFileURL))
    try store.write(old)
    let variant = store.aclVariantFileURL(summary: "global")
    let oldBytes = try Data(contentsOf: variant)
    try store.write(old.replacingACL(.direct(at: store.aclFileURL)))
    let failing = RuntimeFileStore(fileURL: runtime.contract) { data, url in
      if url == self.runtime.contract {
        try FileManager.default.removeItem(at: self.store.aclFileURL)
        try FileManager.default.createDirectory(
          at: self.store.aclFileURL, withIntermediateDirectories: false)
        throw NSError(domain: "contract", code: 1)
      }
      try AtomicFileWriter.write(data, to: url)
    }
    let changed = old.replacingACL(
      ProxyACLDocument(
        path: store.aclFileURL.path, summary: "global",
        content: "[proxy_all]\n[bypass_list]\nexample.com\n"))
    XCTAssertThrowsError(try failing.write(changed)) { error in
      guard case RuntimeFileStore.PersistenceError.rollbackFailed = error else {
        return XCTFail("Expected explicit link rollback failure: \(error)")
      }
    }
    XCTAssertEqual(try Data(contentsOf: variant), oldBytes)
  }

  func testDecodedDocumentRejectsMissingOrSymlinkVariant() throws {
    let document = SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(), acl: .direct(at: store.aclFileURL))
    try store.write(document)
    let decoded = try XCTUnwrap(store.loadDocument())
    let before = try Data(contentsOf: runtime.contract)
    let variant = store.aclVariantFileURL(summary: "direct")
    try FileManager.default.removeItem(at: variant)
    XCTAssertThrowsError(try store.write(decoded))
    try FileManager.default.createSymbolicLink(
      atPath: variant.path, withDestinationPath: runtime.contract.path)
    XCTAssertThrowsError(try store.write(decoded))
    XCTAssertEqual(try Data(contentsOf: runtime.contract), before)
  }

  func testRollbackFailureStillRestoresOtherChangedResources() throws {
    let old = SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(), acl: .direct(at: store.aclFileURL))
    try store.write(old)
    let global = SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(), acl: .global(at: store.aclFileURL))
    try store.write(global)
    try store.write(old)
    let variant = store.aclVariantFileURL(summary: "global")
    var writes = 0
    let failing = RuntimeFileStore(fileURL: runtime.contract) { data, url in
      if url == self.runtime.contract { throw NSError(domain: "contract", code: 1) }
      if url == variant {
        writes += 1
        if writes == 2 { throw NSError(domain: "restore", code: 2) }
      }
      try AtomicFileWriter.write(data, to: url)
    }
    let changed = SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(),
      acl: ProxyACLDocument(
        path: store.aclFileURL.path, summary: "global",
        content: "[proxy_all]\n[bypass_list]\n127.0.0.1\n"))
    XCTAssertThrowsError(try failing.write(changed)) { error in
      guard case RuntimeFileStore.PersistenceError.rollbackFailed = error else {
        return XCTFail("Expected explicit rollback failure: \(error)")
      }
    }
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: store.aclFileURL.path),
      "acl-direct.ini")
    XCTAssertEqual(try Data(contentsOf: runtime.contract), try old.jsonData())
  }

  func testPreparationFailureRestoresWrittenVariantAndReportsRestoreFailure() throws {
    let document = SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(), acl: .direct(at: store.aclFileURL))
    try store.write(document)
    let variant = store.aclVariantFileURL(summary: "direct")
    try FileManager.default.removeItem(at: store.aclFileURL)
    try FileManager.default.createDirectory(
      at: store.aclFileURL, withIntermediateDirectories: false)
    var writes = 0
    let failing = RuntimeFileStore(fileURL: runtime.contract) { data, url in
      if url == variant {
        writes += 1
        if writes == 2 { throw NSError(domain: "restore", code: 1) }
      }
      try AtomicFileWriter.write(data, to: url)
    }
    let changed = document.replacingACL(
      ProxyACLDocument(
        path: store.aclFileURL.path, summary: "direct",
        content: "[bypass_all]\n[proxy_list]\nexample.com\n"))
    XCTAssertThrowsError(try failing.write(changed)) { error in
      guard case RuntimeFileStore.PersistenceError.rollbackFailed = error else {
        return XCTFail("Expected explicit preparation rollback failure: \(error)")
      }
    }
    XCTAssertEqual(writes, 2)
  }

}
