import XCTest

@testable import ShadowsocksX_NG2

/// 订阅快照的目录应用语义（issue #35 验收「overlay 语义与身份连续性」）：
/// enabled 仅按身份精确匹配延续；固定分组身份与 enabled 不变；远端删除不留
/// 墓碑；结构与顺序远端权威。
final class SubscriptionSnapshotApplicationTests: XCTestCase {
  private let groupID = NodeID(rawValue: "sub1:fixed-group")

  private func makeCatalog() throws -> ConfigurationCatalog {
    var catalog = ConfigurationCatalog()
    try catalog.addGroup("订阅分组", source: .subscription, id: groupID)
    let nested = NodeID(rawValue: "sub1:g:jp")
    try catalog.addGroup("日本", source: .subscription, id: nested, to: groupID)
    let serverA = NodeID(rawValue: "sub1:id:a")
    try catalog.addServer(
      CatalogFixtures.serverFields(remark: "香港 01"), source: .subscription, id: serverA,
      to: groupID)
    let serverB = NodeID(rawValue: "sub1:id:b")
    try catalog.addServer(
      CatalogFixtures.serverFields(remark: "日本 02"), source: .subscription, id: serverB,
      to: nested)
    return catalog
  }

  private func leaf(_ id: String, fields: ServerFields = CatalogFixtures.serverFields(remark: ""))
    -> CatalogSubscriptionSnapshot.Child
  {
    .server(CatalogSubscriptionSnapshot.ServerLeaf(id: NodeID(rawValue: id), fields: fields))
  }

  private func group(_ id: String, _ name: String, children: [CatalogSubscriptionSnapshot.Child])
    -> CatalogSubscriptionSnapshot.Child
  {
    .group(
      CatalogSubscriptionSnapshot.Group(id: NodeID(rawValue: id), name: name, children: children))
  }

  // MARK: 快照应用

  func testSnapshotReplacesSubtreeAndCarriesEnabledOverlay() throws {
    var catalog = try makeCatalog()
    // 既有 overlay：a 停用、嵌套分组停用（其下 b 有效停用）。
    try catalog.setEnabled(NodeID(rawValue: "sub1:id:a"), false)

    let document = CatalogSubscriptionSnapshot(
      name: "远端新名",
      root: .init(
        id: groupID, name: "ignored-root",
        children: [
          leaf("sub1:id:b"),
          group(
            "sub1:g:jp", "JP", children: [leaf("sub1:id:a"), leaf("sub1:id:new")]),
        ]))
    let removed = try catalog.applySubscriptionSnapshot(document, into: groupID)

    XCTAssertEqual(removed.count, 2, "旧树两台服务器全部视为移除（b 从嵌套组移到根）")
    // 固定分组身份与 enabled 保持不变，名称跟随远端；远端子序原样落目录。
    let fixed = try XCTUnwrap(catalog.entry(for: groupID))
    XCTAssertEqual(
      try catalog.children(of: groupID),
      [NodeID(rawValue: "sub1:id:b"), NodeID(rawValue: "sub1:g:jp")])
    guard case .group(let fields) = fixed.kind else { return XCTFail("固定分组应存在") }
    XCTAssertEqual(fields.name, "远端新名")
    XCTAssertTrue(fixed.enabled)
    // 精确匹配延续：a 停用保留；新节点默认启用。
    XCTAssertFalse(try XCTUnwrap(catalog.entry(for: NodeID(rawValue: "sub1:id:a"))).enabled)
    XCTAssertTrue(try XCTUnwrap(catalog.entry(for: NodeID(rawValue: "sub1:id:new"))).enabled)
    // 旧树已重建，无墓碑：固定分组 + 根序 b + 嵌套组 + a + 新节点。
    XCTAssertEqual(catalog.entries.count, 5)
  }

  func testRemovedRemoteMembersLeaveNoTombstone() throws {
    var catalog = try makeCatalog()
    let removedTarget = NodeID(rawValue: "sub1:id:b")

    let document = CatalogSubscriptionSnapshot(
      name: "订阅分组", root: .init(id: groupID, name: "", children: [leaf("sub1:id:a")]))
    _ = try catalog.applySubscriptionSnapshot(document, into: groupID)

    XCTAssertNil(catalog.entry(for: removedTarget), "远端删除即移除")
    XCTAssertNil(catalog.entry(for: NodeID(rawValue: "sub1:g:jp")), "空嵌套组一并移除")
    XCTAssertEqual(catalog.entries.count, 2)
  }

  func testFixedGroupDisabledStateSurvivesRefresh() throws {
    var catalog = try makeCatalog()
    try catalog.setEnabled(groupID, false)

    let document = CatalogSubscriptionSnapshot(
      name: "新名", root: .init(id: groupID, name: "", children: [leaf("sub1:id:a")]))
    _ = try catalog.applySubscriptionSnapshot(document, into: groupID)

    XCTAssertFalse(try XCTUnwrap(catalog.entry(for: groupID)).enabled, "固定分组本地开关保留")
  }

  func testApplyToManualGroupRejected() throws {
    var catalog = ConfigurationCatalog()
    let manual = try catalog.addGroup("手动组")
    let document = CatalogSubscriptionSnapshot(
      name: "x", root: .init(id: groupID, name: "", children: []))

    XCTAssertThrowsError(try catalog.applySubscriptionSnapshot(document, into: manual))
  }

  func testApplyToMissingGroupRejected() throws {
    var catalog = ConfigurationCatalog()
    let document = CatalogSubscriptionSnapshot(
      name: "x", root: .init(id: groupID, name: "", children: []))

    XCTAssertThrowsError(
      try catalog.applySubscriptionSnapshot(document, into: NodeID(rawValue: "ghost")))
  }

  // MARK: 订阅子树删除

  func testRemoveSubscriptionSubtreeRemovesEverythingAndReportsCredentials() throws {
    var catalog = try makeCatalog()
    let manual = try catalog.addGroup("手动组", id: NodeID(rawValue: "manual:g"))
    _ = try catalog.addTestServer("手动服务器", id: NodeID(rawValue: "manual:s"), to: manual)

    let removed = try catalog.removeSubscriptionSubtree(of: groupID)

    XCTAssertEqual(removed.count, 4, "固定分组 + 嵌套组 + 两台服务器")
    XCTAssertEqual(catalog.entries.count, 2, "手动子树不受影响")
    XCTAssertFalse(catalog.rootChildren.contains(groupID))
    XCTAssertTrue(removed.allSatisfy { $0.source == .subscription })
    // 返回条目带凭据引用供调用方清理。
    let credentialRefs = removed.compactMap { entry -> CredentialReference? in
      if case .server(let fields) = entry.kind { return fields.passwordRef }
      return nil
    }
    XCTAssertEqual(credentialRefs.count, 2)
  }

  func testRemoveMissingSubscriptionRejected() {
    var catalog = ConfigurationCatalog()
    XCTAssertThrowsError(
      try catalog.removeSubscriptionSubtree(of: NodeID(rawValue: "ghost")))
  }

  // MARK: 订阅子树变更后重展开（接线语义：issue #35 验收 4）

  func testActiveTargetInsideRefreshedSubtreeStillExpandsAfterSnapshot() throws {
    var catalog = try makeCatalog()
    var machine = ActivationStateMachine(activeTargetID: NodeID(rawValue: "sub1:id:a"))
    let credentials = InMemoryCredentialStore()

    // 快照后 a 仍在（身份不变）→ 目标有效，重展开产出部署效应。叶子无插件，
    // 激活校验只依赖凭据解析；快照重建后按目录里的真实引用解析秘密。
    let document = CatalogSubscriptionSnapshot(
      name: "订阅分组",
      root: .init(
        id: groupID, name: "",
        children: [
          .server(
            CatalogSubscriptionSnapshot.ServerLeaf(
              id: NodeID(rawValue: "sub1:id:a"),
              fields: ServerFields(
                address: "203.0.113.1", port: 8388,
                encryptionMethod: "aes-256-gcm", passwordRef: .fresh())))
        ]))
    _ = try catalog.applySubscriptionSnapshot(document, into: groupID)
    for entry in catalog.entries.values {
      if case .server(let fields) = entry.kind {
        try credentials.save("resolved", for: fields.passwordRef)
      }
    }

    let effect = machine.catalogDidCommit(
      catalog, credentials: credentials, plugins: NoManagedPluginProvider(),
      listen: SslocalListenSettings())
    guard case .deployed(let configuration) = try XCTUnwrap(effect) else {
      return XCTFail("身份未变的活动目标应部署而非清除")
    }
    XCTAssertEqual(configuration.targetID, NodeID(rawValue: "sub1:id:a"))

    // 快照清空该目标 → 清除并停止。
    let empty = CatalogSubscriptionSnapshot(
      name: "订阅分组", root: .init(id: groupID, name: "", children: []))
    _ = try catalog.applySubscriptionSnapshot(empty, into: groupID)
    let cleared = machine.catalogDidCommit(
      catalog, credentials: credentials, plugins: NoManagedPluginProvider(),
      listen: SslocalListenSettings())
    guard case .clearedAndStopped = try XCTUnwrap(cleared) else {
      return XCTFail("目标随远端删除消失后应清除并停止")
    }
    XCTAssertNil(machine.activeTargetID)
  }
}
