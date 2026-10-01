import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class HomeServerListStateTests: XCTestCase {
  private var defaults: UserDefaults!
  private var suiteName: String!

  override func setUp() async throws {
    suiteName = "HomeServerListStateTests.\(UUID().uuidString)"
    defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
  }

  override func tearDown() async throws {
    defaults.removePersistentDomain(forName: suiteName)
    defaults = nil
  }

  func testTreePreservesRootOrderAndPureContainerGroups() {
    let state = HomeServerListState(defaults: defaults)
    let tree = fixtureTree()
    state.update(tree: tree, activeTargetID: nil)

    XCTAssertEqual(
      state.visibleRows.map(\.id.rawValue), ["root-server", "outer", "inner", "empty"])
    XCTAssertEqual(state.visibleRows.map(\.depth), [0, 0, 1, 0])
    state.toggleGroup(id("inner"))
    XCTAssertEqual(
      state.visibleRows.map(\.id.rawValue),
      ["root-server", "outer", "inner", "leaf", "invalid", "empty"])
    XCTAssertNil(state.selection)
  }

  private func id(_ value: String) -> NodeID { NodeID(rawValue: value) }

  func testExpansionRestoresAcrossRestartWithoutAffectingManagement() {
    let state = HomeServerListState(defaults: defaults)
    state.update(tree: fixtureTree(), activeTargetID: nil)
    state.toggleGroup(id("inner"))
    state.toggleGroup(id("outer"))

    let restarted = HomeServerListState(defaults: defaults)
    restarted.update(tree: fixtureTree(), activeTargetID: id("leaf"))
    XCTAssertEqual(restarted.visibleRows.map(\.id.rawValue), ["root-server", "outer", "empty"])
    restarted.toggleGroup(id("outer"))
    XCTAssertEqual(
      restarted.visibleRows.map(\.id.rawValue),
      ["root-server", "outer", "inner", "leaf", "invalid", "empty"])
    XCTAssertFalse(CatalogExpansionState().isCollapsed(id("outer")))
  }

  private func fixtureTree() -> CatalogTreeSnapshot {
    let leaf = node("leaf", parent: "inner")
    let invalid = node("invalid", parent: "inner", invalid: true)
    let inner = node("inner", parent: "outer", children: [leaf, invalid])
    return CatalogTreeSnapshot(roots: [
      node("root-server"), node("outer", children: [inner]), node("empty", children: []),
    ])
  }

  func testSelectionAndLocateDoNotImplicitlyFollowActivationChanges() {
    let state = HomeServerListState(defaults: defaults)
    state.update(tree: fixtureTree(), activeTargetID: id("leaf"))
    XCTAssertEqual(state.selection, id("leaf"))
    XCTAssertFalse(state.visibleRows.map(\.id).contains(id("leaf")))
    state.select(id("root-server"))
    state.update(tree: fixtureTree(), activeTargetID: id("inner"))
    XCTAssertEqual(state.selection, id("root-server"))
    state.toggleGroup(id("outer"))
    state.locate(id("leaf"))
    XCTAssertEqual(state.selection, id("leaf"))
    XCTAssertTrue(state.visibleRows.map(\.id).contains(id("leaf")))
    state.toggleGroup(id("inner"))
    XCTAssertEqual(state.selection, id("inner"))
    state.update(tree: CatalogTreeSnapshot(roots: [node("root-server")]), activeTargetID: nil)
    XCTAssertNil(state.selection)
  }

  private func node(
    _ value: String, parent: String? = nil, children: [CatalogTreeNode]? = nil,
    invalid: Bool = false
  ) -> CatalogTreeNode {
    CatalogTreeNode(
      id: id(value), name: value, isGroup: children != nil, source: .manual,
      parentID: parent.map(id),
      invalidReasons: invalid ? [.unsupportedEncryptionMethod("future-cipher")] : [],
      childCount: children?.count ?? 0,
      subtreeNodeCount: children?.reduce(0) { $0 + 1 + $1.subtreeNodeCount } ?? 0,
      invalidDescendantCount: children?.reduce(0) { $0 + $1.subtreeInvalidServerCount } ?? 0,
      children: children)
  }

  func testKeyboardNavigationUsesVisibleRowsAndTreeRelationships() {
    let state = HomeServerListState(defaults: defaults)
    state.update(tree: fixtureTree(), activeTargetID: nil)
    state.navigate(.downward)
    XCTAssertEqual(state.selection, id("root-server"))
    state.navigate(.downward)
    state.navigate(.right)
    XCTAssertEqual(state.selection, id("inner"))
    state.navigate(.right)
    XCTAssertEqual(state.selection, id("inner"), "首次右键只展开")
    state.navigate(.right)
    XCTAssertEqual(state.selection, id("leaf"))
    state.navigate(.left)
    XCTAssertEqual(state.selection, id("inner"))
    state.navigate(.left)
    state.navigate(.downward)
    XCTAssertEqual(state.selection, id("empty"), "跳过隐藏成员")
    state.navigate(.downward)
    XCTAssertEqual(state.selection, id("empty"))
    state.navigate(.upward)
    XCTAssertEqual(state.selection, id("inner"))
  }

  func testOnlySelectedVisibleEligibleNonActiveTargetCanBeActivated() {
    let state = HomeServerListState(defaults: defaults)
    state.update(tree: fixtureTree(), activeTargetID: id("leaf"))
    let eligible = ActivationEligibility(
      canActivate: true, candidateCount: 1, skippedInvalidCount: 0, ineligibility: nil)
    XCTAssertNil(state.activationTarget(activeTargetID: nil, eligibility: eligible))
    state.select(id("root-server"))
    XCTAssertEqual(
      state.activationTarget(activeTargetID: id("outer"), eligibility: eligible), id("root-server"))
    XCTAssertNil(state.activationTarget(activeTargetID: id("root-server"), eligibility: eligible))
    let unavailable = ActivationEligibility(
      canActivate: false, candidateCount: 0, skippedInvalidCount: 1, ineligibility: .noCandidates)
    XCTAssertNil(state.activationTarget(activeTargetID: nil, eligibility: unavailable))
    XCTAssertNil(state.activationTarget(activeTargetID: nil, eligibility: nil))
  }

  func testMovedSelectionFollowsVisibleAncestorAndActiveMarksKeepTargetIdentity() {
    let state = HomeServerListState(defaults: defaults)
    state.update(tree: fixtureTree(), activeTargetID: nil)
    state.select(id("root-server"))
    let moved = node("root-server", parent: "inner")
    let inner = node("inner", parent: "outer", children: [moved])
    state.update(
      tree: CatalogTreeSnapshot(roots: [node("outer", children: [inner])]),
      activeTargetID: id("inner"))
    XCTAssertEqual(state.selection, id("inner"))
    XCTAssertEqual(state.ancestorIDs(for: id("inner")), [id("outer")])
    XCTAssertEqual(state.ancestorIDs(for: id("root-server")), [id("inner"), id("outer")])
    state.locate(id("inner"))
    XCTAssertFalse(state.visibleRows.map(\.id).contains(id("root-server")), "定位组不展开组自身")
  }
}
