import XCTest

@testable import ShadowsocksX_NG2

/// 有效启用语义：有效启用 = 节点及其全部祖先启用（CONTEXT.md「Enabled」）。
final class EffectiveEnablementTests: XCTestCase {
  func testEnabledChainIsEffectivelyEnabled() throws {
    var catalog = ConfigurationCatalog()
    let group = try catalog.addGroup("组")
    let nested = try catalog.addGroup("嵌套组", to: group)
    let leaf = try catalog.addTestServer("leaf", to: nested)

    XCTAssertEqual(try catalog.isEffectivelyEnabled(leaf), true)
    XCTAssertEqual(try catalog.isEffectivelyEnabled(nested), true)
  }

  func testDisabledRootAncestorDisablesDeepLeaf() throws {
    var catalog = ConfigurationCatalog()
    let top = try catalog.addGroup("顶层")
    let middle = try catalog.addGroup("中层", to: top)
    let inner = try catalog.addGroup("内层", to: middle)
    let leaf = try catalog.addTestServer("deep", to: inner)

    try catalog.setEnabled(top, false)

    XCTAssertEqual(try catalog.isEffectivelyEnabled(top), false)
    XCTAssertEqual(try catalog.isEffectivelyEnabled(middle), false)
    XCTAssertEqual(try catalog.isEffectivelyEnabled(inner), false)
    XCTAssertEqual(try catalog.isEffectivelyEnabled(leaf), false, "四层嵌套，最深层随祖先失效")

    try catalog.setEnabled(top, true)
    XCTAssertEqual(try catalog.isEffectivelyEnabled(leaf), true, "恢复祖先即恢复整条链")
  }

  func testDisabledMidGroupOnlyDisablesItsSubtree() throws {
    var catalog = ConfigurationCatalog()
    let group = try catalog.addGroup("组")
    let kept = try catalog.addTestServer("kept", to: group)
    let disabledBranch = try catalog.addGroup("停用分支", to: group)
    let hidden = try catalog.addTestServer("hidden", to: disabledBranch)

    try catalog.setEnabled(disabledBranch, false)

    XCTAssertEqual(try catalog.isEffectivelyEnabled(hidden), false)
    XCTAssertEqual(try catalog.isEffectivelyEnabled(kept), true, "兄弟子树不受影响")
  }

  func testDisabledLeafStaysDisabledInsideEnabledGroup() throws {
    var catalog = ConfigurationCatalog()
    let group = try catalog.addGroup("组")
    let leaf = try catalog.addTestServer("leaf", to: group)

    try catalog.setEnabled(leaf, false)

    XCTAssertEqual(try catalog.isEffectivelyEnabled(leaf), false)
    XCTAssertEqual(try catalog.isEffectivelyEnabled(group), true)
  }

  func testEffectiveEnablementFollowsMoves() throws {
    var catalog = ConfigurationCatalog()
    let enabledGroup = try catalog.addGroup("启用组")
    let disabledGroup = try catalog.addGroup("停用组")
    try catalog.setEnabled(disabledGroup, false)
    let leaf = try catalog.addTestServer("leaf", to: enabledGroup)

    try catalog.move(leaf, to: disabledGroup)
    XCTAssertEqual(try catalog.isEffectivelyEnabled(leaf), false, "启用的叶子移入停用组后失效")

    try catalog.move(leaf, to: nil)
    XCTAssertEqual(try catalog.isEffectivelyEnabled(leaf), true, "移回目录根后恢复")
  }
}
