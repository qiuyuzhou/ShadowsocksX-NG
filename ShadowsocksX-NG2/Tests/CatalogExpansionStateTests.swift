import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class CatalogExpansionStateTests: XCTestCase {
  func testFreshStateIsFullyExpanded() {
    let expansion = CatalogExpansionState()

    XCTAssertTrue(expansion.collapsedGroupIDs.isEmpty)
    XCTAssertFalse(expansion.isCollapsed(NodeID(rawValue: "g1")))
  }

  /// 切换语义：未收起 → 收起 → 再切换 → 展开（分区切换往返不重置的事实基础）。
  func testToggleCollapsesThenReexpands() {
    let expansion = CatalogExpansionState()
    let id = NodeID(rawValue: "g1")

    expansion.toggleCollapsed(id)
    XCTAssertTrue(expansion.isCollapsed(id))

    expansion.toggleCollapsed(id)
    XCTAssertFalse(expansion.isCollapsed(id))
  }

  /// 服务器管理树的各组折叠事实按身份独立保存。
  func testCollapseSetIsKeyedPerGroupID() {
    let expansion = CatalogExpansionState()
    let first = NodeID(rawValue: "g-first")
    let second = NodeID(rawValue: "g-second")

    expansion.toggleCollapsed(first)
    expansion.toggleCollapsed(second)

    XCTAssertEqual(expansion.collapsedGroupIDs, [first, second])

    expansion.toggleCollapsed(first)
    XCTAssertEqual(expansion.collapsedGroupIDs, [second])
    XCTAssertFalse(expansion.isCollapsed(first))
    XCTAssertTrue(expansion.isCollapsed(second))
  }
}
