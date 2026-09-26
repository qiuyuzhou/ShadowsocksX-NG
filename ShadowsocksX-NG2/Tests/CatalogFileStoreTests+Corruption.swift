import XCTest

@testable import ShadowsocksX_NG2

extension CatalogFileStoreTests {
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
}
