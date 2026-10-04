import Foundation
import Testing

@testable import ShadowsocksX_NG2

@MainActor
struct ServerFormLoadingTests {
  @Test
  func missingReferencedPasswordFailsLoadingInsteadOfBecomingEmpty() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CatalogFileStore(fileURL: directory.appendingPathComponent("catalog.json"))
    var catalog = ConfigurationCatalog()
    let id = try catalog.addServer(
      ServerFields(
        address: "203.0.113.1", port: 8388, encryptionMethod: "aes-256-gcm",
        passwordRef: .fresh(), remark: "服务器"))
    try store.save(CatalogDocument(catalog: catalog))
    let workflow = makeCatalogWorkflow(
      coordinator: CatalogCommitCoordinator(fileStore: store, runtime: FakeCatalogRuntime()),
      credentials: InMemoryCredentialStore())
    #expect(throws: (any Error).self) { _ = try workflow.serverEditForm(for: id) }
  }
  @Test
  func appearingAgainAndUpdatingPresentationDoNotReloadManualDraft() {
    let fields = ServerFormFields()
    let id = NodeID(rawValue: "manual")
    var reads = 0
    let load = { (_: NodeID) -> ServerEditForm? in
      reads += 1
      return Self.form()
    }
    fields.showServer(id, load: load)
    fields.remark = "未保存名称"
    fields.showServer(id, load: load)
    fields.updatePresentation(ServerFormPresentation(isEditable: true, plugin: Self.form().plugin))
    #expect(reads == 1)
    #expect(fields.remark == "未保存名称")
    #expect(fields.hasChanges)
    fields.reloadServer(load: load)
    #expect(reads == 2)
    #expect(fields.remark == "服务器")
    #expect(!fields.hasChanges)
  }

  @Test
  func resetFailurePreservesManualDraftButBlocksSavingUntilReloadSucceeds() {
    let fields = ServerFormFields()
    fields.showServer(NodeID(rawValue: "manual")) { _ in Self.form() }
    fields.password = "edited password"
    fields.reloadServer { _ in throw ServerFormLoadError.credentialsUnavailable }
    #expect(fields.password == "edited password")
    #expect(fields.hasLoadedServer)
    #expect(!fields.canSaveServer)
    #expect(fields.loadFailure == .credentialsUnavailable)
    fields.reloadServer { _ in Self.form(password: "latest") }
    #expect(fields.password == "latest")
    #expect(fields.canSaveServer)
    #expect(fields.loadFailure == nil)
    #expect(!fields.hasChanges)
  }

  @Test
  func failedSelectionNeverShowsPreviousServerAndLateSaveDoesNotResetNewDraft() {
    let fields = ServerFormFields()
    let first = NodeID(rawValue: "first")
    let second = NodeID(rawValue: "second")
    fields.showServer(first) { _ in Self.form() }
    fields.showServer(second) { _ in throw ServerFormLoadError.credentialsUnavailable }
    #expect(fields.password.isEmpty)
    #expect(fields.address.isEmpty)
    #expect(!fields.hasLoadedServer)
    #expect(!fields.canSaveServer)
    fields.reloadServer { _ in Self.form(password: "second password") }
    fields.password = "unsaved second password"
    fields.didSaveServer(first) { _ in
      Issue.record("保存其他服务器不应装载当前草稿")
      return Self.form()
    }
    #expect(fields.password == "unsaved second password")
    fields.didSaveServer(second) { _ in Self.form(password: "saved second password") }
    #expect(fields.password == "saved second password")
    #expect(!fields.hasChanges)
  }

  @Test
  func onlyAffectedReadOnlyServerReloadsAndFailedReloadClearsOldFields() {
    let fields = ServerFormFields()
    let id = NodeID(rawValue: "subscription")
    fields.showServer(id) { _ in Self.form(isEditable: false) }
    fields.subscriptionDidRefresh(affectedServers: [NodeID(rawValue: "other")]) { _ in
      Issue.record("其他订阅不应触发装载")
      return nil
    }
    #expect(fields.password == "pw")
    fields.subscriptionDidRefresh(affectedServers: [id]) { _ in
      throw ServerFormLoadError.credentialsUnavailable
    }
    #expect(fields.password.isEmpty)
    #expect(fields.portText.isEmpty)
    #expect(fields.pluginOptions.composedString == "")
    #expect(!fields.hasLoadedServer)
    #expect(fields.loadFailure == .credentialsUnavailable)
    fields.updatePresentation(
      ServerFormPresentation(isEditable: false, plugin: Self.form().plugin))
    fields.subscriptionDidRefresh(affectedServers: [id]) { _ in
      Self.form(isEditable: false, password: "new password")
    }
    #expect(fields.password == "new password")
    #expect(fields.loadFailure == nil)

    fields.showServer(NodeID(rawValue: "manual")) { _ in Self.form() }
    fields.password = "manual draft"
    fields.subscriptionDidRefresh(affectedServers: [fields.serverID!]) { _ in
      Issue.record("手动草稿不应自动装载")
      return nil
    }
    #expect(fields.password == "manual draft")
  }

  @Test
  func presentationReadsNoSecretsAndReferencedManagedOptionsMustLoad() async throws {
    let credentials = FormCredentialStore()
    try await Self.withWorkflow(credentials: credentials) { workflow in
      let program = ManagedPluginCatalog.plugins[0].program
      let id = try await workflow.createServer(
        ServerEditDraft(
          address: "203.0.113.1", port: 8388, encryptionMethod: "aes-256-gcm",
          password: "pw", remark: "服务器", plugin: .managed(program: program),
          pluginOptions: "mode=websocket"), into: nil)
      credentials.reads = 0
      credentials.failReads = true
      let presentation = try #require(workflow.serverFormPresentation(for: id))
      #expect(presentation.isEditable)
      #expect(presentation.plugin.optionsPresent)
      #expect(presentation.plugin.options.isEmpty)
      #expect(credentials.reads == 0)
      #expect(throws: ServerFormLoadError.credentialsUnavailable) {
        _ = try workflow.serverEditForm(for: id)
      }
      credentials.failReads = false
      let form = try #require(try workflow.serverEditForm(for: id))
      #expect(form.password == "pw")
      #expect(form.plugin.options == "mode=websocket")
      let optionsRef = try #require(
        credentials.storage.storageSnapshot.first(where: { $0.value == "mode=websocket" })?.key)
      try credentials.delete(CredentialReference(rawValue: optionsRef))
      #expect(throws: ServerFormLoadError.credentialsUnavailable) {
        _ = try workflow.serverEditForm(for: id)
      }
    }
  }

  @Test
  func successfulRefreshReloadsSecretChangesDespiteEqualTreeAndFailureDoesNotReload() async throws {
    let fetcher = FakeSubscriptionFetcher(behavior: .success(SubscriptionDocs.flat(serverCount: 1)))
    let credentials = InMemoryCredentialStore()
    try await Self.withWorkflow(credentials: credentials, fetcher: fetcher) { workflow in
      let summary = try await workflow.createSubscription(urlString: "https://example.com/sub.json")
      let server = try #require(workflow.tree.node(withID: summary.groupID)?.childNodes.first)
      let fields = ServerFormFields()
      fields.showServer(server.id, load: workflow.serverEditForm)
      let oldTree = workflow.tree
      var reloads = 0
      let observation = workflow.subscriptionServerRefreshes.sink { affected in
        fields.updatePresentation(workflow.serverFormPresentation(for: server.id))
        fields.subscriptionDidRefresh(affectedServers: affected) { id in
          reloads += 1
          return try workflow.serverEditForm(for: id)
        }
      }
      defer { observation.cancel() }
      let original = try #require(
        String(data: SubscriptionDocs.flat(serverCount: 1), encoding: .utf8))
      let changed = original.replacingOccurrences(
        of: "\"password\": \"pw\"", with: "\"password\": \"new password\"")
      fetcher.setBehavior(.success(Data(changed.utf8)))
      await workflow.refreshSubscription(summary.id)
      #expect(workflow.tree == oldTree)
      #expect(fields.password == "new password")
      #expect(reloads == 1)
      fetcher.setBehavior(.failure(.transport(detail: "fixture failure")))
      await workflow.refreshSubscription(summary.id)
      #expect(reloads == 1)
      #expect(fields.password == "new password")
      fetcher.setBehavior(.success(Data(changed.utf8)))
      _ = try await workflow.createSubscription(urlString: "https://other.example/sub.json")
      #expect(reloads == 1)
    }
  }

  private static func withWorkflow(
    credentials: CredentialStoring,
    fetcher: SubscriptionFetching = FakeSubscriptionFetcher(behavior: .success(Data())),
    _ body: (CatalogWorkflow) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let workflow = makeCatalogWorkflow(
      coordinator: CatalogCommitCoordinator(
        fileStore: CatalogFileStore(fileURL: directory.appendingPathComponent("catalog.json")),
        runtime: FakeCatalogRuntime()),
      credentials: credentials, subscriptionFetcher: fetcher)
    try await body(workflow)
  }

  private static func form(isEditable: Bool = true, password: String = "pw") -> ServerEditForm {
    ServerEditForm(
      address: "203.0.113.1", port: 8388, encryptionMethod: "aes-256-gcm",
      password: password, remark: "服务器",
      plugin: PluginSectionState(
        selection: .none, managed: ManagedPluginCatalog.plugins, provided: false,
        optionsPresent: false, options: ""), isEditable: isEditable)
  }
}

private final class FormCredentialStore: CredentialStoring {
  let storage = InMemoryCredentialStore()
  var reads = 0
  var failReads = false

  func secret(for reference: CredentialReference) throws -> String? {
    reads += 1
    if failReads { throw CredentialStoreError.secretNotUTF8 }
    return try storage.secret(for: reference)
  }

  func save(_ secret: String, for reference: CredentialReference) throws {
    try storage.save(secret, for: reference)
  }

  func delete(_ reference: CredentialReference) throws { try storage.delete(reference) }
}
