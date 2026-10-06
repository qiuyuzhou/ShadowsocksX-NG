import Foundation
import Testing

@testable import ShadowsocksX_NG2

@MainActor
struct CatalogWorkflowDuplicateTests {
  @Test func subscriptionCopyPreservesWholeTreeAsManual() async throws {
    let source = try CatalogFixtures.makeSubscriptionFixture()
    var catalog = source.catalog
    try catalog.addGroup("Empty", source: .subscription, to: source.nestedGroupID)
    let fixture = try DuplicateFixture(catalog: catalog)
    for id in source.serverIDs {
      guard case .server(let fields) = catalog.entry(for: id)?.kind else { continue }
      try fixture.credentials.save("password", for: fields.passwordRef)
      if let reference = fields.pluginOptionsRef {
        try fixture.credentials.save("mode=websocket;host=example.com", for: reference)
      }
    }
    let workflow = fixture.workflow
    #expect(workflow.canDuplicate(source.groupID))
    #expect(!workflow.canDuplicate(source.nestedGroupID))
    #expect(!workflow.canDuplicate(source.serverIDs[0]))
    #expect(!workflow.canDuplicate(NodeID.fresh()))
    let copy = try await workflow.duplicate(source.groupID, nameSuffix: "副本")
    #expect(workflow.tree.roots.map(\.id) == [source.groupID, copy])
    let root = try #require(workflow.tree.node(withID: copy))
    #expect(root.name == "订阅分组 副本")
    #expect(root.childNodes.map(\.name) == ["嵌套分组", "香港 01"])
    let nested = try #require(root.childNodes.first)
    #expect(nested.childNodes.map(\.name) == ["日本 02", "Empty"])
    let originalRoot = try #require(workflow.tree.node(withID: source.groupID))
    #expect(root.subtreeIDs.isDisjoint(with: originalRoot.subtreeIDs))
    for id in root.subtreeIDs {
      #expect(workflow.tree.node(withID: id)?.isManual == true)
    }
    let server = try #require(nested.childNodes.first)
    #expect(
      try workflow.serverDetailPluginOptions(for: server.id) == "mode=websocket;host=example.com")
    _ = try await workflow.remove(copy)
    #expect(
      try workflow.serverDetailPluginOptions(for: source.serverIDs[1])
        == "mode=websocket;host=example.com")
    await #expect(throws: CatalogError.subscriptionNodeImmutable(source.nestedGroupID)) {
      _ = try await workflow.duplicate(source.nestedGroupID, nameSuffix: "Copy")
    }
  }

  @Test func nestedManualGroupCopyKeepsInvalidFieldsAndEmptyGroups() async throws {
    var catalog = ConfigurationCatalog()
    let parent = try catalog.addGroup("Parent")
    let original = try catalog.addGroup("Group", to: parent)
    let fields = ServerFields(
      address: "203.0.113.7", port: 8388, encryptionMethod: "future-cipher",
      passwordRef: .fresh(), remark: "Invalid", pluginProgram: nil, pluginOptionsRef: .fresh())
    try catalog.addServer(fields, to: original)
    try catalog.addGroup("Empty", to: original)
    try catalog.addGroup("Group Copy", to: parent)
    let fixture = try DuplicateFixture(catalog: catalog)
    try fixture.credentials.save("password", for: fields.passwordRef)
    try fixture.credentials.save("unknown;flag;flag=", for: try #require(fields.pluginOptionsRef))
    let copy = try await fixture.workflow.duplicate(original, nameSuffix: "Copy")
    let node = try #require(fixture.workflow.tree.node(withID: copy))
    #expect(node.parentID == parent)
    #expect(node.name == "Group Copy 2")
    #expect(node.childNodes.map(\.name) == ["Invalid", "Empty"])
    let leaf = try #require(node.childNodes.first)
    #expect(leaf.isInvalid)
    #expect(
      fixture.workflow.serverDetailPresentation(for: leaf.id)?.encryptionMethod == "future-cipher")
    #expect(try fixture.workflow.serverDetailPluginOptions(for: leaf.id) == "unknown;flag;flag=")
    let reloaded = makeCatalogWorkflow(
      coordinator: CatalogCommitCoordinator(
        fileStore: CatalogFileStore(fileURL: fixture.fileURL), runtime: FakeCatalogRuntime()),
      credentials: fixture.credentials)
    #expect(reloaded.tree.node(withID: copy)?.childNodes.map(\.name) == ["Invalid", "Empty"])
  }

  @Test(arguments: ["missing", "read", "write", "persistence", "rollback"])
  func failuresDoNotPublishPartialCopies(stage: String) async throws {
    var catalog = ConfigurationCatalog()
    let group = try catalog.addGroup("Group")
    let fields = CatalogFixtures.serverFields(remark: "Server")
    try catalog.addServer(fields, to: group)
    let store = DuplicateCredentialStore()
    try store.save("password", for: fields.passwordRef)
    try store.save("options", for: try #require(fields.pluginOptionsRef))
    let fixture = try DuplicateFixture(catalog: catalog, credentialStore: store)
    let before = store.backing.storageSnapshot
    switch stage {
    case "missing": store.missing = fields.pluginOptionsRef
    case "read": store.unreadable = fields.pluginOptionsRef
    case "write", "rollback": store.savesRemaining = 1
    default:
      let gate = fixture.directory.appendingPathComponent("gate")
      try FileManager.default.removeItem(at: gate)
      try Data().write(to: gate)
    }
    store.failDelete = stage == "rollback"
    do {
      _ = try await fixture.workflow.duplicate(group, nameSuffix: "Copy")
      Issue.record("Expected the complete copy to fail")
    } catch let error as CommitError {
      if stage == "rollback" {
        if case .partial = error.credentialRollback {
        } else {
          Issue.record("Incomplete rollback must be reported")
        }
      }
    }
    #expect(fixture.workflow.tree.roots.map(\.id) == [group])
    if stage != "rollback" { #expect(store.backing.storageSnapshot == before) }
    #expect(try store.backing.secret(for: fields.passwordRef) == "password")
    #expect(try store.backing.secret(for: try #require(fields.pluginOptionsRef)) == "options")
  }

  @Test func runtimeFailureRetainsCommittedCopy() async throws {
    let fixture = try DuplicateFixture()
    let original = try await fixture.workflow.createServer(fixture.draft, into: nil)
    fixture.runtime.hasActiveTarget = true
    fixture.runtime.defaultOutcome = .failed(failure: nil)
    let copy = try await fixture.workflow.duplicate(original, nameSuffix: "Copy")
    await waitUntilRuntimeSettles(fixture.workflow.runtimeSync != .syncing(generation: 2))
    #expect(
      fixture.workflow.runtimeSync == .finished(generation: 2, outcome: .failed(failure: nil)))
    #expect(fixture.workflow.tree.containsNode(copy))
    #expect(fixture.runtime.convergeSnapshots.last?.catalog.rootChildren == [original, copy])
  }

  @Test(arguments: ["副本", "Copy"])
  func copyingCopiesUsesOneSuffixAndSiblingNumbers(suffix: String) async throws {
    let fixture = try DuplicateFixture()
    let workflow = fixture.workflow
    let original = try await workflow.createGroup(named: "websocket", into: nil)
    let first = try await workflow.duplicate(original, nameSuffix: suffix)
    let second = try await workflow.duplicate(first, nameSuffix: suffix)
    let third = try await workflow.duplicate(second, nameSuffix: suffix)
    #expect(workflow.displayName(for: first) == "websocket \(suffix)")
    #expect(workflow.displayName(for: second) == "websocket \(suffix) 2")
    #expect(workflow.displayName(for: third) == "websocket \(suffix) 3")
    let otherSuffix = suffix == "Copy" ? "副本" : "Copy"
    let fourth = try await workflow.duplicate(third, nameSuffix: otherSuffix)
    #expect(workflow.displayName(for: fourth) == "websocket \(suffix) 4")
    let detached = try await workflow.createGroup(named: "Detached \(suffix) 2", into: nil)
    let detachedCopy = try await workflow.duplicate(detached, nameSuffix: suffix)
    #expect(workflow.displayName(for: detachedCopy) == "Detached \(suffix) 3")
    let interior = try await workflow.createGroup(named: "websocket \(suffix) backup", into: nil)
    let interiorCopy = try await workflow.duplicate(interior, nameSuffix: suffix)
    #expect(workflow.displayName(for: interiorCopy) == "websocket \(suffix) backup \(suffix)")
  }

  @Test func serverCopyIsAdjacentAndIndependent() async throws {
    let fixture = try DuplicateFixture()
    let workflow = fixture.workflow
    let parent = try await workflow.createGroup(named: "Parent", into: nil)
    let original = try await workflow.createServer(fixture.draft, into: parent)
    let next = try await workflow.createGroup(named: "Next", into: parent)
    let copy = try await workflow.duplicate(original, nameSuffix: "Copy")
    #expect(workflow.tree.node(withID: parent)?.childNodes.map(\.id) == [original, copy, next])
    #expect(workflow.displayName(for: copy) == "Server Copy")
    #expect(try workflow.serverEditForm(for: copy)?.password == "password")
    var edited = fixture.draft
    edited.password = "changed"
    try await workflow.updateServer(copy, draft: edited)
    #expect(try workflow.serverEditForm(for: original)?.password == "password")
    _ = try await workflow.remove(copy)
    #expect(try workflow.serverEditForm(for: original)?.password == "password")
    let copy2 = try await workflow.duplicate(original, nameSuffix: "Copy")
    let copy3 = try await workflow.duplicate(original, nameSuffix: "Copy")
    #expect(workflow.displayName(for: copy2) == "Server Copy")
    #expect(workflow.displayName(for: copy3) == "Server Copy 2")
  }
}

@MainActor
private final class DuplicateFixture {
  let directory: URL
  let fileURL: URL
  let credentials = InMemoryCredentialStore()
  let runtime = FakeCatalogRuntime()
  let workflow: CatalogWorkflow
  var draft: ServerEditDraft {
    ServerEditDraft(
      address: "203.0.113.7", port: 8388, encryptionMethod: "aes-256-gcm",
      password: "password", remark: "Server", plugin: .none, pluginOptions: nil)
  }

  init(
    catalog: ConfigurationCatalog = ConfigurationCatalog(),
    credentialStore: CredentialStoring? = nil
  ) throws {
    directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("duplicate-\(UUID().uuidString)")
    fileURL = directory.appendingPathComponent("gate/catalog.json")
    try CatalogFileStore(fileURL: fileURL).save(CatalogDocument(catalog: catalog))
    workflow = makeCatalogWorkflow(
      coordinator: CatalogCommitCoordinator(
        fileStore: CatalogFileStore(fileURL: fileURL), runtime: runtime),
      credentials: credentialStore ?? credentials)
  }

  deinit { try? FileManager.default.removeItem(at: directory) }
}

private final class DuplicateCredentialStore: CredentialStoring {
  let backing = InMemoryCredentialStore()
  var missing: CredentialReference?
  var unreadable: CredentialReference?
  var savesRemaining: Int?
  var failDelete = false

  func secret(for reference: CredentialReference) throws -> String? {
    if reference == unreadable { throw CredentialStoreError.secretNotUTF8 }
    if reference == missing { return nil }
    return try backing.secret(for: reference)
  }

  func save(_ secret: String, for reference: CredentialReference) throws {
    if let remaining = savesRemaining {
      guard remaining > 0 else { throw CredentialStoreError.secretNotUTF8 }
      savesRemaining = remaining - 1
    }
    try backing.save(secret, for: reference)
  }

  func delete(_ reference: CredentialReference) throws {
    if failDelete { throw CredentialStoreError.secretNotUTF8 }
    try backing.delete(reference)
  }
}
