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

  /// 两处服务器树（服务器侧栏/首页目标树）共用同一实例：同一分组身份在两处
  /// 读到同一折叠事实，互不覆盖。
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
