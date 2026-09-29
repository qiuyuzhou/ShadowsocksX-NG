import XCTest

@testable import ShadowsocksX_NG2

/// The workflow export draft is the public seam for complete SIP-008 serialization.
@MainActor
final class ConfigurationGroupExportTests: XCTestCase {
  private var workDir: URL!
  private var catalogFileURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var fetcher: FakeSubscriptionFetcher!
  private var workflow: CatalogWorkflow!

  override func setUp() async throws {
    try await super.setUp()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("group-export-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    catalogFileURL = workDir.appendingPathComponent("catalog.json")
    credentials = InMemoryCredentialStore()
    fetcher = FakeSubscriptionFetcher(behavior: .success(Data()))
    workflow = makeWorkflow()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: workDir)
    try await super.tearDown()
  }

  func testDraftContainsFlattenedServersAndOrderedGroupTree() async throws {
    let rootID = try await workflow.createGroup(named: "组 根", into: nil)
    let firstID = try await addServer(
      host: "203.0.113.1", password: "first-secret", remark: "First", into: rootID)
    let nestedID = try await workflow.createGroup(named: "嵌套", into: rootID)
    let nestedServerID = try await addServer(
      host: "203.0.113.2", password: "nested-secret", remark: "Nested", into: nestedID)
    let lastID = try await addServer(
      host: "203.0.113.3", password: "last-secret", remark: "Last", into: rootID)

    let draft = try workflow.configurationGroupExportDraft(for: rootID)

    XCTAssertEqual(draft.suggestedFileName, "组 根.json")
    let document = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.data) as? [String: Any])
    XCTAssertEqual(document["version"] as? Int, 1)
    let servers = try XCTUnwrap(document["servers"] as? [[String: Any]])
    XCTAssertEqual(
      servers.compactMap { $0["server"] as? String },
      [
        "203.0.113.1", "203.0.113.2", "203.0.113.3",
      ])
    XCTAssertEqual(
      servers.compactMap { $0["password"] as? String },
      [
        "first-secret", "nested-secret", "last-secret",
      ])
    XCTAssertEqual(servers.compactMap { $0["remarks"] as? String }, ["First", "Nested", "Last"])
    let serverIDValues = servers.compactMap { $0["id"] as? String }
    XCTAssertEqual(serverIDValues.compactMap { UUID(uuidString: $0) }.count, 3)
    XCTAssertEqual(
      UUID(uuidString: try XCTUnwrap(serverIDValues.first)), UUID(uuidString: firstID.rawValue))
    XCTAssertEqual(
      UUID(uuidString: try XCTUnwrap(serverIDValues.dropFirst().first)),
      UUID(uuidString: nestedServerID.rawValue))
    XCTAssertEqual(
      UUID(uuidString: try XCTUnwrap(serverIDValues.last)), UUID(uuidString: lastID.rawValue))

    let extensionObject = try XCTUnwrap(document["x_shadowsocksx_ng"] as? [String: Any])
    XCTAssertEqual(extensionObject["schema_version"] as? Int, 1)
    let groups = try XCTUnwrap(extensionObject["groups"] as? [[String: Any]])
    let rootGroupID = try XCTUnwrap(extensionObject["root_group_id"] as? String)
    let rootGroup = try XCTUnwrap(groups.first { $0["id"] as? String == rootGroupID })
    XCTAssertEqual(rootGroup["name"] as? String, "组 根")
    let nestedGroup = try XCTUnwrap(groups.first { $0["name"] as? String == "嵌套" })
    let rootChildren = try XCTUnwrap(rootGroup["children"] as? [[String: String]])
    let nestedGroupIDValue = try XCTUnwrap(nestedGroup["id"] as? String)
    XCTAssertEqual(
      rootChildren,
      [
        ["type": "server", "id": try XCTUnwrap(servers[0]["id"] as? String)],
        ["type": "group", "id": nestedGroupIDValue],
        ["type": "server", "id": try XCTUnwrap(servers[2]["id"] as? String)],
      ])

  }

  func testSubscriptionExportPreservesProviderIDsAndDerivesStableIDs() async throws {
    let providerID = "aaaaaaaa-0000-4000-8000-00000000000a"
    let nestedProviderID = "bbbbbbbb-0000-4000-8000-00000000000b"
    fetcher.setBehavior(
      .success(
        subscriptionDocument(
          providerID: providerID, nestedProviderID: nestedProviderID)))
    workflow = makeWorkflow()
    let subscription = try await workflow.createSubscription(
      urlString: "https://provider.example.com/config.json")
    let root = try XCTUnwrap(workflow.tree.node(withID: subscription.groupID))
    let nested = try XCTUnwrap(root.childNodes.first(where: \.isGroup))

    let rootDraft = try workflow.configurationGroupExportDraft(for: subscription.groupID)
    let repeatedRootDraft = try workflow.configurationGroupExportDraft(for: subscription.groupID)
    let nestedDraft = try workflow.configurationGroupExportDraft(for: nested.id)
    let rootServers = try jsonServers(in: rootDraft)
    let nestedServers = try jsonServers(in: nestedDraft)
    let rootIDs = rootServers.compactMap { $0["id"] as? String }
    let nestedIDs = nestedServers.compactMap { $0["id"] as? String }

    XCTAssertEqual(rootIDs[0], providerID.uppercased())
    XCTAssertEqual(rootIDs[1], nestedProviderID.uppercased())
    XCTAssertEqual(nestedIDs, [nestedProviderID.uppercased()])
    let repeatedRootIDs = try jsonServers(in: repeatedRootDraft).compactMap { $0["id"] as? String }
    XCTAssertEqual(rootIDs[2], repeatedRootIDs[2], "无 provider UUID 的服务器身份稳定")
    XCTAssertNotNil(UUID(uuidString: try XCTUnwrap(rootIDs[2])))

    let rootExtension = try groupExtension(in: rootDraft)
    let nestedExtension = try groupExtension(in: nestedDraft)
    let rootExportID = try XCTUnwrap(rootExtension["root_group_id"] as? String)
    let nestedExportID = try XCTUnwrap(nestedExtension["root_group_id"] as? String)
    let providerRootExportID = try groupID(named: "Provider root", in: rootDraft)
    let nestedGroupExportID = try groupID(named: "Nested", in: rootDraft)
    XCTAssertEqual(rootExportID, providerRootExportID)
    XCTAssertEqual(nestedExportID, nestedGroupExportID, "分组 ID 不随导出根变化")
  }

  func testExportabilityUsesServerPresenceNotActivationValidity() async throws {
    var catalog = ConfigurationCatalog()
    let emptyRoot = NodeID.fresh()
    let emptyNested = NodeID.fresh()
    let exportRoot = NodeID.fresh()
    let invalidServer = NodeID.fresh()
    try catalog.addGroup("空组", id: emptyRoot)
    try catalog.addGroup("空子组", id: emptyNested, to: emptyRoot)
    try catalog.addGroup("含无效服务器", id: exportRoot)
    let passwordRef = CredentialReference.fresh()
    let optionsRef = CredentialReference.fresh()
    try credentials.save("password", for: passwordRef)
    try credentials.save("obfs=http", for: optionsRef)
    try catalog.addServer(
      ServerFields(
        address: "203.0.113.8", port: 8388, encryptionMethod: "aes-256-gcm",
        passwordRef: passwordRef, remark: "activation-invalid", pluginProgram: "missing-plugin",
        pluginOptionsRef: optionsRef),
      id: invalidServer, to: exportRoot)
    try install(catalog)

    let empty = try XCTUnwrap(workflow.tree.node(withID: emptyRoot))
    let emptyChild = try XCTUnwrap(workflow.tree.node(withID: emptyNested))
    let nonCandidate = try XCTUnwrap(workflow.tree.node(withID: invalidServer))
    let exportableGroup = try XCTUnwrap(workflow.tree.node(withID: exportRoot))
    XCTAssertFalse(empty.containsServerConfiguration)
    XCTAssertFalse(emptyChild.containsServerConfiguration)
    XCTAssertTrue(nonCandidate.isInvalid, "插件未提供使服务器不具备激活资格")
    XCTAssertTrue(exportableGroup.containsServerConfiguration)

    let servers = try jsonServers(in: workflow.configurationGroupExportDraft(for: exportRoot))
    XCTAssertEqual(servers.first?["plugin"] as? String, "missing-plugin")
    XCTAssertEqual(servers.first?["plugin_opts"] as? String, "obfs=http")
  }

  func testPluginOptionsWithoutProgramFailsBeforeCallingExporter() async throws {
    var catalog = ConfigurationCatalog()
    let rootID = NodeID.fresh()
    let serverID = NodeID.fresh()
    let passwordRef = CredentialReference.fresh()
    let optionsRef = CredentialReference.fresh()
    try credentials.save("password", for: passwordRef)
    try credentials.save("mode=websocket", for: optionsRef)
    try catalog.addGroup("不完整组", id: rootID)
    try catalog.addServer(
      ServerFields(
        address: "203.0.113.9", port: 8388, encryptionMethod: "aes-256-gcm",
        passwordRef: passwordRef, pluginOptionsRef: optionsRef),
      id: serverID, to: rootID)
    try install(catalog)
    let exporter = InMemoryConfigurationGroupFileExporter()

    let outcome = ConfigurationGroupExportAction(workflow: workflow, exporter: exporter)
      .perform(for: rootID)

    XCTAssertEqual(outcome, .preparationFailed(.pluginOptionsWithoutProgram(serverID)))
    XCTAssertTrue(exporter.drafts.isEmpty, "不完整文档不能进入保存面板")
  }

  func testExportActionPropagatesCancelSaveAndWriteFailure() async throws {
    let rootID = try await workflow.createGroup(named: "动作", into: nil)
    _ = try await addServer(host: "203.0.113.10", password: "pw", remark: "node", into: rootID)
    let exporter = InMemoryConfigurationGroupFileExporter()

    exporter.result = .cancelled
    XCTAssertEqual(
      ConfigurationGroupExportAction(workflow: workflow, exporter: exporter).perform(for: rootID),
      .cancelled)
    let savedURL = URL(fileURLWithPath: "/tmp/group.json")
    exporter.result = .saved(savedURL)
    XCTAssertEqual(
      ConfigurationGroupExportAction(workflow: workflow, exporter: exporter).perform(for: rootID),
      .saved(savedURL))
    exporter.result = .failed(.writeFailed)
    XCTAssertEqual(
      ConfigurationGroupExportAction(workflow: workflow, exporter: exporter).perform(for: rootID),
      .exportFailed(.writeFailed))
    XCTAssertEqual(exporter.drafts.count, 3)
  }

  private func makeWorkflow() -> CatalogWorkflow {
    makeCatalogWorkflow(
      coordinator: CatalogCommitCoordinator(
        fileStore: CatalogFileStore(fileURL: catalogFileURL), runtime: FakeCatalogRuntime()),
      credentials: credentials,
      subscriptionFetcher: fetcher)
  }

  private func install(_ catalog: ConfigurationCatalog) throws {
    try CatalogFileStore(fileURL: catalogFileURL).save(CatalogDocument(catalog: catalog))
    workflow = makeWorkflow()
  }

  private func subscriptionDocument(providerID: String, nestedProviderID: String) -> Data {
    Data(
      """
      {
        "version": 1,
        "servers": [
          {"id":"\(providerID)","remarks":"root server","server":"203.0.113.11",
           "server_port":8388,"password":"p1","method":"aes-256-gcm"},
          {"id":"\(nestedProviderID)","remarks":"nested server","server":"203.0.113.12",
           "server_port":8389,"password":"p2","method":"aes-256-gcm"},
          {"remarks":"idless","server":"203.0.113.13","server_port":8390,
           "password":"p3","method":"aes-256-gcm"}
        ],
        "x_shadowsocksx_ng": {
          "schema_version": 1,
          "root_group_id": "provider-root",
          "groups": [
            {"id":"provider-root","name":"Provider root","children":[
              {"type":"server","id":"\(providerID)"},
              {"type":"group","id":"nested"}]},
            {"id":"nested","name":"Nested","children":[
              {"type":"server","id":"\(nestedProviderID)"}]}
          ]
        }
      }
      """.utf8)
  }

  private func jsonServers(in draft: ConfigurationGroupExportDraft) throws -> [[String: Any]] {
    let document = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.data) as? [String: Any])
    return try XCTUnwrap(document["servers"] as? [[String: Any]])
  }

  private func groupExtension(in draft: ConfigurationGroupExportDraft) throws -> [String: Any] {
    let document = try XCTUnwrap(JSONSerialization.jsonObject(with: draft.data) as? [String: Any])
    return try XCTUnwrap(document["x_shadowsocksx_ng"] as? [String: Any])
  }

  private func groupID(named name: String, in draft: ConfigurationGroupExportDraft) throws -> String
  {
    let groups = try XCTUnwrap(groupExtension(in: draft)["groups"] as? [[String: Any]])
    return try XCTUnwrap(groups.first { $0["name"] as? String == name }?["id"] as? String)
  }

  private func addServer(
    host: String, password: String, remark: String, into parent: NodeID
  ) async throws -> NodeID {
    let uri = SsUri(
      method: "aes-256-gcm", password: password, host: host, port: 8388, remark: remark
    ).encode()
    let result = try await workflow.createServers(fromURIs: uri, into: parent)
    XCTAssertEqual(result.addedCount, 1)
    return try XCTUnwrap(workflow.tree.node(withID: parent)?.childNodes.last?.id)
  }
}
