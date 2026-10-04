import Foundation
import Security
import Testing

@testable import ShadowsocksX_NG2

@MainActor
struct SubscriptionInformationWorkflowTests {
  @Test func successfulInformationSurvivesFailureAndReload() async throws {
    try await withWorkflow { workflow, store, credentials, fetcher in
      let summary = try await workflow.createSubscription(urlString: "https://p.example.com/sub")
      #expect(summary.information?.bytesUsed == 25)
      #expect(summary.information?.bytesRemaining == 75)
      let succeededAt = try #require(summary.lastSucceededAt)
      if case .succeeded(let attemptAt) = summary.status {
        #expect(succeededAt == attemptAt)
      } else {
        Issue.record("应成功提交")
      }
      fetcher.setBehavior(.failure(.httpStatus(code: 503)))
      await workflow.refreshSubscription(summary.id)
      let failed = try #require(workflow.subscriptions.first)
      #expect(failed.information == summary.information)
      #expect(failed.lastSucceededAt == succeededAt)
      let reloaded = makeCatalogWorkflow(
        coordinator: CatalogCommitCoordinator(fileStore: store, runtime: FakeCatalogRuntime()),
        credentials: credentials)
      #expect(reloaded.subscriptions.first?.information == summary.information)
      #expect(reloaded.subscriptions.first?.lastSucceededAt == succeededAt)
    }
  }

  @Test func successfulRefreshReplacesMissingAndInvalidFields() async throws {
    try await withWorkflow { workflow, _, _, fetcher in
      let first = try await workflow.createSubscription(urlString: "https://p.example.com/sub")
      fetcher.setBehavior(
        .success(
          Data(
            #"{"version":1,"servers":[],"bytes_used":50,"bytes_remaining":-1,"expires_at":123}"#
              .utf8)))
      await workflow.refreshSubscription(first.id)
      let replaced = try #require(workflow.subscriptions.first)
      #expect(replaced.information?.bytesUsed == 50)
      #expect(replaced.information?.bytesRemaining == nil)
      #expect(replaced.information?.expiresAt == nil)

      fetcher.setBehavior(.success(Data(#"{"version":1,"servers":[]}"#.utf8)))
      await workflow.refreshSubscription(first.id)
      let empty = try #require(workflow.subscriptions.first)
      #expect(empty.information == nil)
      if case .succeeded(let date) = empty.status {
        #expect(empty.lastSucceededAt == date)
        #expect(date >= first.lastSucceededAt!)
      } else {
        Issue.record("无资料响应仍应成功")
      }
    }
  }

  @Test func cancelledRefreshCannotCommitEvenIfFetcherReturnsData() async throws {
    try await withWorkflow { workflow, store, credentials, _ in
      let first = try await workflow.createSubscription(urlString: "https://p.example.com/sub")
      let bytes = try Data(contentsOf: store.fileURL)
      let fetcher = InformationGateFetcher()
      let reloaded = makeCatalogWorkflow(
        coordinator: CatalogCommitCoordinator(fileStore: store, runtime: FakeCatalogRuntime()),
        credentials: credentials, subscriptionFetcher: fetcher)
      let refresh = Task { await reloaded.refreshSubscription(first.id) }
      await fetcher.entered.wait()
      refresh.cancel()
      fetcher.release.release()
      await refresh.value
      #expect(reloaded.subscriptions.first == first)
      #expect(try Data(contentsOf: store.fileURL) == bytes)
    }
  }

  @Test func persistenceFailureDoesNotPublishNewInformation() async throws {
    try await withWorkflow { workflow, store, _, fetcher in
      let first = try await workflow.createSubscription(urlString: "https://p.example.com/sub")
      let tree = workflow.tree
      // 只破坏本夹具的文件路径，让原子替换失败，不影响其他 runner。
      let directory = URL(fileURLWithPath: store.fileURL.deletingLastPathComponent().path)
      try FileManager.default.removeItem(at: directory)
      try Data().write(to: directory)
      fetcher.setBehavior(.success(Data(#"{"version":1,"servers":[],"bytes_used":100}"#.utf8)))
      await workflow.refreshSubscription(first.id)
      #expect(workflow.subscriptions.first?.information == first.information)
      #expect(workflow.subscriptions.first?.lastSucceededAt == first.lastSucceededAt)
      #expect(workflow.tree == tree)
    }
  }

  @Test func durableDocumentContainsOnlyAllowlistedInformationAndCredentialReferences() async throws
  {
    try await withWorkflow { workflow, store, credentials, fetcher in
      fetcher.setBehavior(
        .success(
          Data(
            #"""
            {"version":1,
            "servers":[{"server":"203.0.113.7",
            "server_port":8388,
            "method":"aes-256-gcm",
            "password":"RAW-SERVER-PASSWORD",
            "plugin":"v2ray-plugin",
            "plugin_opts":"RAW-PLUGIN-OPTIONS"}],
            "bytes_used":18446744073709551615,
            "provider_token":"RAW-PROVIDER-TOKEN"}
            """#
            .utf8)))
      let first = try await workflow.createSubscription(
        urlString: "https://p.example.com/sub?secret=RAW-URL-TOKEN")
      #expect(first.information?.bytesUsed == UInt64.max)
      let raw = try String(contentsOf: store.fileURL, encoding: .utf8)
      for secret in [
        "RAW-SERVER-PASSWORD", "RAW-PLUGIN-OPTIONS", "RAW-PROVIDER-TOKEN", "RAW-URL-TOKEN",
      ] {
        #expect(!raw.contains(secret))
      }
      let reloaded = makeCatalogWorkflow(
        coordinator: CatalogCommitCoordinator(fileStore: store, runtime: FakeCatalogRuntime()),
        credentials: credentials)
      #expect(reloaded.subscriptions.first?.information?.bytesUsed == UInt64.max)
    }
  }

  @Test func oldDocumentWithoutInformationOrSuccessfulTimeLoadsWithoutGuessing() async throws {
    try await withWorkflow { workflow, store, credentials, _ in
      _ = try await workflow.createSubscription(urlString: "https://p.example.com/sub")
      var document = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
      var records = try #require(document["subscriptions"] as? [[String: Any]])
      records[0].removeValue(forKey: "information")
      records[0].removeValue(forKey: "lastSucceededAt")
      document["subscriptions"] = records
      try JSONSerialization.data(withJSONObject: document).write(to: store.fileURL)
      let reloaded = makeCatalogWorkflow(
        coordinator: CatalogCommitCoordinator(fileStore: store, runtime: FakeCatalogRuntime()),
        credentials: credentials)
      #expect(reloaded.subscriptions.count == 1)
      #expect(reloaded.subscriptions.first?.information == nil)
      #expect(reloaded.subscriptions.first?.lastSucceededAt == nil)
    }
  }

  @Test func credentialFailureKeepsInformationAndSuccessfulTime() async throws {
    try await withWorkflow { workflow, store, credentials, fetcher in
      let first = try await workflow.createSubscription(urlString: "https://p.example.com/sub")
      let before = credentials.storageSnapshot
      let rejecting = RejectingInformationCredentials(base: credentials)
      let reloaded = makeCatalogWorkflow(
        coordinator: CatalogCommitCoordinator(fileStore: store, runtime: FakeCatalogRuntime()),
        credentials: rejecting, subscriptionFetcher: fetcher)
      fetcher.setBehavior(
        .success(
          Data(
            #"""
            {"version":1,
            "servers":[{"server":"203.0.113.7",
            "server_port":8388,
            "method":"aes-256-gcm",
            "password":"REJECT-THIS-PASSWORD"}],
            "bytes_used":100}
            """#
            .utf8)))
      await reloaded.refreshSubscription(first.id)
      let failed = try #require(reloaded.subscriptions.first)
      #expect(failed.information == first.information)
      #expect(failed.lastSucceededAt == first.lastSucceededAt)
      if case .failed(_, let failure) = failed.status {
        #expect(failure == .commit(category: .credentials, rollback: .restored))
      } else {
        Issue.record("凭据失败应记失败态")
      }
      #expect(credentials.storageSnapshot == before)
      #expect(try store.load().subscriptions.first?.information == first.information)
    }
  }

  @Test func cancellationDuringCredentialWritesRollsBackWithoutPublishing() async throws {
    try await withWorkflow { workflow, store, credentials, fetcher in
      let first = try await workflow.createSubscription(urlString: "https://p.example.com/sub")
      let before = credentials.storageSnapshot
      let bytes = try Data(contentsOf: store.fileURL)
      let reloaded = makeCatalogWorkflow(
        coordinator: CatalogCommitCoordinator(fileStore: store, runtime: FakeCatalogRuntime()),
        credentials: CancellingInformationCredentials(base: credentials),
        subscriptionFetcher: fetcher)
      fetcher.setBehavior(
        .success(
          Data(
            #"""
            {"version":1,"servers":[{"server":"203.0.113.7","server_port":8388,
            "method":"aes-256-gcm","password":"CANCEL-DURING-SAVE"}],"bytes_used":100}
            """#.utf8)))
      let refresh = Task { await reloaded.refreshSubscription(first.id) }
      await refresh.value
      #expect(reloaded.subscriptions.first == first)
      #expect(credentials.storageSnapshot == before)
      #expect(try Data(contentsOf: store.fileURL) == bytes)
    }
  }

  private func withWorkflow(
    _ body:
      @MainActor (
        CatalogWorkflow, CatalogFileStore, InMemoryCredentialStore, FakeSubscriptionFetcher
      ) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("subscription-information-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CatalogFileStore(fileURL: directory.appendingPathComponent("catalog.json"))
    let credentials = InMemoryCredentialStore()
    let fetcher = FakeSubscriptionFetcher(
      behavior: .success(
        Data(#"{"version":1,"servers":[],"bytes_used":25,"bytes_remaining":75}"#.utf8)))
    let workflow = makeCatalogWorkflow(
      coordinator: CatalogCommitCoordinator(fileStore: store, runtime: FakeCatalogRuntime()),
      credentials: credentials, subscriptionFetcher: fetcher)
    try await body(workflow, store, credentials, fetcher)
  }
}

private struct InformationGateFetcher: SubscriptionFetching {
  let entered = AsyncGate()
  let release = AsyncGate()

  func fetch(_ url: URL) async throws -> Data {
    entered.release()
    await release.wait()
    return Data(#"{"version":1,"servers":[],"bytes_used":100}"#.utf8)
  }
}

private struct RejectingInformationCredentials: CredentialStoring {
  let base: InMemoryCredentialStore

  func save(_ secret: String, for reference: CredentialReference) throws {
    guard secret != "REJECT-THIS-PASSWORD" else {
      throw CredentialStoreError.keychainStatus(errSecAuthFailed)
    }
    try base.save(secret, for: reference)
  }

  func secret(for reference: CredentialReference) throws -> String? {
    try base.secret(for: reference)
  }

  func delete(_ reference: CredentialReference) throws {
    try base.delete(reference)
  }
}

private struct CancellingInformationCredentials: CredentialStoring {
  let base: InMemoryCredentialStore

  func save(_ secret: String, for reference: CredentialReference) throws {
    try base.save(secret, for: reference)
    if secret == "CANCEL-DURING-SAVE" {
      withUnsafeCurrentTask { $0?.cancel() }
    }
  }

  func secret(for reference: CredentialReference) throws -> String? {
    try base.secret(for: reference)
  }

  func delete(_ reference: CredentialReference) throws {
    try base.delete(reference)
  }
}
