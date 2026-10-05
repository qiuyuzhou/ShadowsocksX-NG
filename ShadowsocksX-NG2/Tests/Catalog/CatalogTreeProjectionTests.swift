import XCTest

@testable import ShadowsocksX_NG2

/// CatalogTreeSnapshot 树投影的纯单元测试：折叠可见行与服务器叶子计数。
/// 直接构造 snapshot（memberwise init），不经工作流。
final class CatalogTreeProjectionTests: XCTestCase {
  private func server(_ id: String) -> CatalogTreeNode {
    CatalogTreeNode(
      id: NodeID(rawValue: id), name: id, isGroup: false, source: .manual, parentID: nil,
      invalidReasons: [], childCount: 0, subtreeNodeCount: 0, invalidDescendantCount: 0,
      children: nil)
  }

  private func group(_ id: String, children: [CatalogTreeNode]) -> CatalogTreeNode {
    CatalogTreeNode(
      id: NodeID(rawValue: id), name: id, isGroup: true, source: .manual, parentID: nil,
      invalidReasons: [], childCount: children.count,
      subtreeNodeCount: children.reduce(0) { $0 + 1 + $1.subtreeNodeCount },
      invalidDescendantCount: 0, children: children)
  }

  /// 两层嵌套 + 根叶子 + 空组：覆盖深度、子树跳过与空组语义。
  private func nestedTree() -> CatalogTreeSnapshot {
    CatalogTreeSnapshot(roots: [
      server("root-server"),
      group(
        "outer",
        children: [
          group("inner", children: [server("deep-leaf")]),
          server("outer-leaf"),
        ]),
      group("empty", children: []),
    ])
  }

  // MARK: - 可见行折叠投影

  func testVisibleRowsWalkDepthFirstWithDepth() {
    let rows = nestedTree().visibleRows(collapsed: [])
    XCTAssertEqual(
      rows.map(\.id.rawValue),
      ["root-server", "outer", "inner", "deep-leaf", "outer-leaf", "empty"])
    XCTAssertEqual(rows.map(\.depth), [0, 0, 1, 2, 1, 0])
    XCTAssertEqual(rows.map(\.node.name), rows.map(\.id.rawValue), "行身份即节点身份")
  }

  func testVisibleRowsSkipCollapsedSubtrees() {
    let tree = nestedTree()
    XCTAssertEqual(
      tree.visibleRows(collapsed: [NodeID(rawValue: "outer")]).map(\.id.rawValue),
      ["root-server", "outer", "empty"], "收起组的子树不出现，组行自身保留可再展开")
    XCTAssertEqual(
      tree.visibleRows(collapsed: [NodeID(rawValue: "inner")]).map(\.id.rawValue),
      ["root-server", "outer", "inner", "outer-leaf", "empty"])
  }

  func testVisibleRowsTreatUnknownAndLeafIDsAsInert() {
    let collapsed: Set<NodeID> = [NodeID(rawValue: "nope"), NodeID(rawValue: "root-server")]
    XCTAssertEqual(
      nestedTree().visibleRows(collapsed: collapsed).map(\.id.rawValue),
      ["root-server", "outer", "inner", "deep-leaf", "outer-leaf", "empty"])
  }

  // MARK: - 服务器叶子计数

  func testServerLeafCountCountsLeavesAcrossNesting() {
    XCTAssertEqual(nestedTree().serverLeafCount, 3)
    XCTAssertEqual(CatalogTreeSnapshot(roots: []).serverLeafCount, 0)
  }
}
