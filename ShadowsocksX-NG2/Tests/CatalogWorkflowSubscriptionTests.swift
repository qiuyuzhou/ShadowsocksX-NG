import Security
import XCTest

@testable import ShadowsocksX_NG2

/// 订阅端到端语义（issue #35/#41）经目录工作流 module interface 观察：创建
/// 门禁、刷新失败保留快照、身份连续性、URL 编辑保身份、删除递归清除、卡片
/// projection 与提交接线。获取走 FakeSubscriptionFetcher（传输侧契约在
/// SubscriptionFetcherTests）；提交后的运行时收敛以确定性 fake 计数（issue #40）。
@MainActor
final class CatalogWorkflowSubscriptionTests: XCTestCase {
  private var workDir: URL!
  private var fileURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var fetcher: FakeSubscriptionFetcher!
  private var runtime: FakeCatalogRuntime!
  private var workflow: CatalogWorkflow!

  override func setUp() async throws {
    try await super.setUp()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("subscription-workflow-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    fileURL = workDir.appendingPathComponent("catalog.json")
    credentials = InMemoryCredentialStore()
    runtime = FakeCatalogRuntime()
    fetcher = FakeSubscriptionFetcher(behavior: .success(SubscriptionDocs.flat(serverCount: 1)))
    workflow = makeWorkflow()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: workDir)
    try await super.tearDown()
  }

  private func makeWorkflow() -> CatalogWorkflow {
    // 计数即提交计数：提交后的运行时收敛由协调器异步调度（issue #40）。
    runtime.hasActiveTarget = true
    let coordinator = CatalogCommitCoordinator(
      fileStore: CatalogFileStore(fileURL: fileURL), runtime: runtime)
    return CatalogWorkflow(
      coordinator: coordinator,
      credentials: credentials,
      plugins: NoManagedPluginProvider(),
      subscriptionFetcher: fetcher!)
  }

  /// 文档稳定 ID 后缀在树 projection 中定位节点（订阅前缀随机）。
  private func findNode(withSuffix suffix: String) -> CatalogTreeNode? {
    var stack = workflow.tree.roots
    while let node = stack.popLast() {
      if node.id.rawValue.hasSuffix(suffix) { return node }
      stack.append(contentsOf: node.children ?? [])
    }
    return nil
  }

  private var serverAID: NodeID {
    findNode(withSuffix: "aaaaaaaa-0000-4000-8000-00000000000a")?.id
      ?? NodeID(rawValue: "missing-a")
  }

  private var serverBID: NodeID {
    findNode(withSuffix: "bbbbbbbb-0000-4000-8000-00000000000b")?.id
      ?? NodeID(rawValue: "missing-b")
  }

  /// b 移到根 + a 改名 + 重排（远端改名/移动/排序跟随的对照文档）。
  private var treeDoc: Data { SubscriptionDocs.tree() }
  private var changedTreeDoc: Data { SubscriptionDocs.treeRenamedAndReordered() }

  // MARK: 创建门禁

  func testCreateRequiresHTTPSURL() async {
    for bad in ["http://example.com/sub.json", "ftp://x/y", "不是 URL", "https://"] {
      do {
        _ = try await workflow.createSubscription(urlString: bad)
        XCTFail("「\(bad)」应被拒绝")
      } catch {
        XCTAssertEqual(error as? SubscriptionFormError, .invalidURL)
      }
    }
    XCTAssertTrue(workflow.subscriptions.isEmpty, "创建失败不留半成品")
    XCTAssertTrue(workflow.tree.isEmpty)
  }

  func testCreateAddsRecordEmptyGroupAndRefreshes() async throws {
    fetcher = FakeSubscriptionFetcher(behavior: .success(treeDoc))
    workflow = makeWorkflow()

    let summary = try await workflow.createSubscription(
      urlString: "https://provider.example.com/sub.json")

    XCTAssertEqual(summary.id, workflow.subscriptions.first?.id)
    XCTAssertEqual(fetcher.lastURL?.host, "provider.example.com", "创建即首次刷新")
    let group = try XCTUnwrap(workflow.tree.node(withID: summary.groupID))
    XCTAssertTrue(group.isGroup)
    XCTAssertEqual(group.name, "Example subscription", "名称跟随远端根分组")
    XCTAssertFalse(group.isManual)
    guard case .succeeded = workflow.subscriptions[0].status else {
      return XCTFail("首次刷新成功应记成功态")
    }
  }

  func testFirstRefreshFailureLeavesEmptyGroupWithFailedStatus() async throws {
    fetcher = FakeSubscriptionFetcher(
      behavior: .failure(.transport(detail: "URLError.timedOut")))
    workflow = makeWorkflow()

    let created = try await workflow.createSubscription(
      urlString: "https://provider.example.com/s.json")

    XCTAssertNotNil(workflow.tree.node(withID: created.groupID), "首刷失败仍留空分组")
    XCTAssertEqual(created.name, "provider.example.com", "空分组以 host 兜底")
    guard case .failed(_, let reason) = workflow.subscriptions[0].status else {
      return XCTFail("首刷失败应记失败态")
    }
    XCTAssertEqual(reason, .transport(.timedOut))
  }

  // MARK: 失败保留语义

  func testFailedRefreshKeepsSnapshotAndStatus() async throws {
    fetcher = FakeSubscriptionFetcher(behavior: .success(treeDoc))
    workflow = makeWorkflow()
    let record = try await workflow.createSubscription(urlString: "https://p.example.com/s.json")
    let convergesBefore = runtime.convergeCount
    let treeBefore = workflow.tree

    fetcher = FakeSubscriptionFetcher(behavior: .failure(.httpStatus(code: 503)))
    workflow.subscriptionFetcher = fetcher
    await workflow.refreshSubscription(record.id)

    // 快照原样保留。
    XCTAssertEqual(workflow.tree, treeBefore, "传输失败不动最后成功快照（projection 等价）")
    XCTAssertEqual(findNode(withSuffix: "aaaaaaaa-0000-4000-8000-00000000000a")?.name, "香港 01")
    // 状态点名失败且原因脱敏。
    guard case .failed(_, let failure) = workflow.subscriptions[0].status else {
      return XCTFail("应记失败态")
    }
    XCTAssertEqual(failure, .httpStatus(code: 503))
    // 仅状态提交了一次（快照未动）。
    await waitUntilRuntimeSettles(runtime.convergeCount - convergesBefore == 1)
    XCTAssertEqual(runtime.convergeCount - convergesBefore, 1)
  }

  func testDuplicateIDFailureKeepsSnapshot() async throws {
    let record = try await seedSuccessfulSubscription()
    let treeBefore = workflow.tree

    workflow.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.duplicateIDs()))
    await workflow.refreshSubscription(record.id)

    guard case .failed(_, let failure) = workflow.subscriptions[0].status else {
      return XCTFail("应记失败态")
    }
    XCTAssertEqual(failure, .duplicateIdentity)
    XCTAssertEqual(workflow.tree, treeBefore)
  }

  func testRecordValidationFailureKeepsSnapshot() async throws {
    let record = try await seedSuccessfulSubscription()
    let treeBefore = workflow.tree

    workflow.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.invalidRecord()))
    await workflow.refreshSubscription(record.id)

    guard case .failed(_, let failure) = workflow.subscriptions[0].status else {
      return XCTFail("应记失败态")
    }
    XCTAssertEqual(failure, .recordValidation(index: 0, field: .port))
    XCTAssertEqual(workflow.tree, treeBefore)
  }

  // MARK: 空快照与扁平回退

  func testEmptySnapshotIsSuccessAndClearsSubtree() async throws {
    let record = try await seedSuccessfulSubscription()

    workflow.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.flat(serverCount: 0)))
    await workflow.refreshSubscription(record.id)

    let group = try XCTUnwrap(workflow.tree.node(withID: record.groupID))
    XCTAssertTrue(group.isGroup)
    XCTAssertEqual(group.childCount, 0, "合法空快照清空子树")
    guard case .succeeded = workflow.subscriptions[0].status else {
      return XCTFail("空快照按成功处理")
    }
  }

  func testCycleDocumentFallsBackToFlatAndSucceeds() async throws {
    let record = try await seedSuccessfulSubscription()

    workflow.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.cycleExtension()))
    await workflow.refreshSubscription(record.id)

    let group = try XCTUnwrap(workflow.tree.node(withID: record.groupID))
    XCTAssertEqual(group.childCount, 2, "回退扁平：标准服务器直接进固定分组")
    XCTAssertEqual(group.name, "p.example.com", "扁平回退以 host 兜底名称")
    guard case .succeeded = workflow.subscriptions[0].status else {
      return XCTFail("回退扁平仍是成功刷新")
    }
  }

  // MARK: 身份连续性

  func testRemoteRenameMoveReorderFollowsWithoutLocalOverlay() async throws {
    fetcher = FakeSubscriptionFetcher(behavior: .success(treeDoc))
    workflow = makeWorkflow()
    let record = try await workflow.createSubscription(urlString: "https://p.example.com/s.json")
    workflow.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(changedTreeDoc))
    await workflow.refreshSubscription(record.id)

    // 身份不变；名称/位置/顺序跟随远端。
    XCTAssertEqual(findNode(withSuffix: "aaaaaaaa-0000-4000-8000-00000000000a")?.name, "香港 01（新名）")
    let group = try XCTUnwrap(workflow.tree.node(withID: record.groupID))
    let japanGroupID = try XCTUnwrap(
      findNode(withSuffix: "g:jp")?.id,
      "嵌套分组应存在")
    XCTAssertEqual(group.children?.map(\.id), [serverBID, japanGroupID], "远端排序跟随")
  }

  func testIdLessServerContinuityOnlyForExactMatch() async throws {
    fetcher = FakeSubscriptionFetcher(behavior: .success(SubscriptionDocs.idLess()))
    workflow = makeWorkflow()
    let record = try await workflow.createSubscription(urlString: "https://p.example.com/s.json")
    let serverID = try XCTUnwrap(onlyServerChildID(ofGroup: record.groupID))
    // 完全相同记录 → 身份延续。
    await workflow.refreshSubscription(record.id)
    XCTAssertEqual(onlyServerChildID(ofGroup: record.groupID), serverID)

    // 端口变化 → 新身份：旧节点删除（无墓碑）。
    workflow.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.idLess(port: 9999)))
    await workflow.refreshSubscription(record.id)
    XCTAssertNil(workflow.tree.node(withID: serverID), "无稳定 ID 且记录变化即不同节点")
    let newID = try XCTUnwrap(onlyServerChildID(ofGroup: record.groupID))
    XCTAssertNotEqual(newID, serverID)
  }

  // MARK: URL 编辑与删除

  func testEditURLKeepsIdentityAndRetainsSnapshotUntilSuccess() async throws {
    let record = try await seedSuccessfulSubscription()
    let originalRecordID = record.id
    let originalGroupID = record.groupID

    // 新地址先失败：快照保留、身份不动。
    let failing = FakeSubscriptionFetcher(behavior: .failure(.httpStatus(code: 404)))
    workflow.subscriptionFetcher = failing
    try await workflow.editSubscriptionURL(
      record.id, urlString: "https://other.example.com/v2.json")
    XCTAssertEqual(workflow.subscriptions[0].id, originalRecordID, "订阅身份保留")
    guard case .failed = workflow.subscriptions[0].status else {
      return XCTFail("新地址失败应记失败态")
    }
    XCTAssertEqual(failing.lastURL?.host, "other.example.com")
    XCTAssertNotNil(findNode(withSuffix: "aaaaaaaa-0000-4000-8000-00000000000a"), "失败保留最后成功快照")

    // 新地址成功：同一身份命名空间下应用新内容。
    workflow.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.flat(serverCount: 1)))
    await workflow.refreshSubscription(record.id)
    XCTAssertEqual(workflow.subscriptions[0].groupID, originalGroupID)
    guard case .succeeded = workflow.subscriptions[0].status else {
      return XCTFail("换址成功应记成功态，实际 \(workflow.subscriptions[0].status)")
    }
    XCTAssertEqual(workflow.tree.roots.count, 1)
  }

  func testEditURLRequiresHTTPS() async throws {
    let record = try await seedSuccessfulSubscription()
    await expectThrowsAsync(
      { try await workflow.editSubscriptionURL(record.id, urlString: "http://p.example.com/x") },
      onThrow: { error in
        XCTAssertEqual(error as? SubscriptionFormError, .invalidURL)
      })
  }

  func testRemoveSubscriptionClearsSubtreeCredentialsAndReportsInvalidation() async throws {
    let record = try await seedSuccessfulSubscription()
    // 身份在删除前捕获(删除后树上已不存在)。
    let serverA = serverAID
    let serverB = serverBID
    let convergesBefore = runtime.convergeCount

    let outcome = try await workflow.removeSubscription(record.id)

    XCTAssertTrue(workflow.subscriptions.isEmpty, "订阅记录移除")
    XCTAssertNil(workflow.tree.node(withID: record.groupID), "固定分组递归清除")
    XCTAssertNil(workflow.tree.node(withID: serverA))
    XCTAssertNil(workflow.tree.node(withID: serverB))
    XCTAssertTrue(
      outcome.removedNodeIDs.contains(serverA) && outcome.removedNodeIDs.contains(record.groupID)
        && outcome.removedNodeIDs.contains(serverB),
      "删除结果携带被删子树身份（selection invalidation，story 18/30）")
    XCTAssertNil(readURLSecret(), "订阅 URL 凭据一并清理")
    await waitUntilRuntimeSettles(runtime.convergeCount - convergesBefore == 1)
    XCTAssertEqual(runtime.convergeCount - convergesBefore, 1, "删除经提交协调器触发活动目标重展开")
  }

  // MARK: 批量刷新与持久化

  func testRefreshAllRefreshesEverySubscription() async throws {
    _ = try await seedSuccessfulSubscription()
    _ = try await createOnly(urlString: "https://q.example.com/t.json")
    let requestsBefore = fetcher.requestCount
    let convergesBefore = runtime.convergeCount

    await workflow.refreshAllSubscriptions()

    XCTAssertEqual(fetcher.requestCount - requestsBefore, 2, "每个订阅各刷一次")
    for summary in workflow.subscriptions {
      guard case .succeeded = summary.status else {
        return XCTFail("全部订阅都应记成功态：\(summary.id)")
      }
    }
    await waitUntilRuntimeSettles(runtime.convergeCount - convergesBefore == 2)
    XCTAssertEqual(runtime.convergeCount - convergesBefore, 2)
  }

  func testSubscriptionsPersistAcrossWorkflowReload() async throws {
    let record = try await seedSuccessfulSubscription()

    let reloaded = CatalogWorkflow(
      coordinator: CatalogCommitCoordinator(
        fileStore: CatalogFileStore(fileURL: fileURL), runtime: FakeCatalogRuntime()),
      credentials: credentials,
      plugins: NoManagedPluginProvider())
    XCTAssertEqual(reloaded.subscriptions.count, 1)
    XCTAssertEqual(reloaded.subscriptions[0].id, record.id)
    guard case .succeeded = reloaded.subscriptions[0].status else {
      return XCTFail("刷新状态跨持久化保留")
    }
    XCTAssertNotNil(reloaded.tree.node(withID: serverAID), "订阅子树跨持久化保留")
  }

  // MARK: 并发守卫

  func testConcurrentRefreshOnSameSubscriptionDoesNotReenter() async throws {
    let record = try await seedSuccessfulSubscription()
    let gated = GatedFetcher()
    workflow.subscriptionFetcher = gated

    async let first: Void = workflow.refreshSubscription(record.id)
    // 轮询而非阻塞等待：主线程阻塞会饿死继承 MainActor 的 async let 子任务。
    while !gated.didEnterFetch {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    await workflow.refreshSubscription(record.id)

    XCTAssertEqual(gated.requestCount, 1, "同一订阅刷新进行中不重入")
    gated.releaseAll()
    await first
    XCTAssertTrue(workflow.refreshingSubscriptionIDs.isEmpty, "完成后守卫释放")
  }

  // MARK: 夹具与辅助

  private func onlyServerChildID(ofGroup groupID: NodeID) -> NodeID? {
    guard let group = workflow.tree.node(withID: groupID),
      group.childCount == 1,
      let only = group.children?.first,
      !only.isGroup
    else { return nil }
    return only.id
  }

  /// 订阅 URL 秘密的观察口：创建后恰有一个订阅 URL 凭据；删除后应为 nil。
  /// （凭据引用不进投影；经存储快照里的唯一 URL 值反查。）
  private func readURLSecret() -> String? {
    credentials.storageSnapshot.values.first { $0.hasPrefix("https://") }
  }

  /// 建一个「创建 + 首刷成功（tree 文档，服务器 a/b）」的订阅。
  private func seedSuccessfulSubscription() async throws -> SubscriptionSummary {
    fetcher = FakeSubscriptionFetcher(behavior: .success(SubscriptionDocs.tree()))
    workflow = makeWorkflow()
    return try await createOnly(urlString: "https://p.example.com/s.json")
  }

  private func createOnly(urlString: String) async throws -> SubscriptionSummary {
    try await workflow.createSubscription(urlString: urlString)
  }
}

extension CatalogWorkflowSubscriptionTests {
  // MARK: Typed failure projection

  func testDecodeAndSchemaFailuresMarkFailedWithoutTouchingSnapshot() async throws {
    let record = try await seedSuccessfulSubscription()

    for (behavior, expected) in [
      (
        FakeSubscriptionFetcher.Behavior.failure(.contentType(received: "text/plain")),
        SubscriptionRefreshFailure.contentType(.unsupported)
      ),
      (
        FakeSubscriptionFetcher.Behavior.success(Data("not json".utf8)),
        SubscriptionRefreshFailure.decodingFailure
      ),
      (
        FakeSubscriptionFetcher.Behavior.success(Data(#"{"version": 9, "servers": []}"#.utf8)),
        SubscriptionRefreshFailure.unsupportedSchemaVersion
      ),
    ] {
      let treeBefore = workflow.tree
      workflow.subscriptionFetcher = FakeSubscriptionFetcher(behavior: behavior)
      await workflow.refreshSubscription(record.id)

      guard case .failed(_, let failure) = workflow.subscriptions[0].status else {
        return XCTFail("应记失败态：\(behavior)")
      }
      XCTAssertEqual(failure, expected)
      XCTAssertEqual(workflow.tree, treeBefore, "解析类失败不动快照（projection 等价）")
    }
  }

  func testSubscriptionSummaryReflectsStatusAndCounts() async throws {
    _ = try await seedSuccessfulSubscription()
    let healthy = try XCTUnwrap(workflow.subscriptions.first)
    XCTAssertEqual(healthy.name, "Example subscription")
    XCTAssertEqual(healthy.host, "p.example.com", "卡片展示 host，不展示完整 URL（story 23）")
    guard case .succeeded = healthy.status else { return XCTFail("应记成功态") }
    XCTAssertEqual(healthy.serverCount, 2)

    workflow.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .failure(.transport(detail: "URLError.cannotConnectToHost")))
    await workflow.refreshSubscription(healthy.id)

    let failed = try XCTUnwrap(workflow.subscriptions.first)
    XCTAssertTrue(failed.status.isFailed)
    guard case .failed(_, let failure) = failed.status else {
      return XCTFail("应保留 typed 失败事实")
    }
    XCTAssertEqual(failure, .transport(.connection))
    XCTAssertEqual(failed.status.failureDetail, "订阅连接失败")
    XCTAssertEqual(failed.serverCount, 2, "失败保留最后成功的服务器数")
  }

  func testPartialCredentialRollbackIsTransientAndPersistedCoarsely() async throws {
    let partialStore = SubscriptionRollbackCredentialStore()
    runtime.hasActiveTarget = true
    let partialWorkflow = CatalogWorkflow(
      coordinator: CatalogCommitCoordinator(
        fileStore: CatalogFileStore(fileURL: fileURL), runtime: runtime),
      credentials: partialStore,
      plugins: NoManagedPluginProvider(),
      subscriptionFetcher: FakeSubscriptionFetcher(
        behavior: .success(SubscriptionDocs.tree())))
    let record = try await partialWorkflow.createSubscription(
      urlString: "https://p.example.com/s.json")
    let snapshotBefore = partialWorkflow.tree
    let serverID = try XCTUnwrap(
      partialWorkflow.tree.node(withID: record.groupID)?.children?.first(where: { !$0.isGroup })?.id
    )
    let loadedCatalog = try CatalogFileStore(fileURL: fileURL).load().catalog
    let serverEntry = try XCTUnwrap(loadedCatalog.entry(for: serverID))
    guard case .server(let fields) = serverEntry.kind else {
      return XCTFail("订阅快照应包含服务器")
    }
    let otherPasswordRefs: Set<CredentialReference> = Set(
      (try loadedCatalog.subscriptionSubtree(of: record.groupID)).compactMap { entry in
        guard case .server(let candidate) = entry.kind,
          candidate.passwordRef != fields.passwordRef
        else {
          return nil
        }
        return candidate.passwordRef
      })
    partialStore.failSave(for: fields.passwordRef)

    await partialWorkflow.refreshSubscription(record.id)

    XCTAssertEqual(partialWorkflow.tree, snapshotBefore, "提交失败保留最后成功快照")
    guard case .failed(_, let failure) = partialWorkflow.subscriptions[0].status else {
      return XCTFail("凭据提交失败应写入失败状态")
    }
    XCTAssertEqual(
      failure,
      .commit(category: .credentials, rollback: .incomplete))
    XCTAssertEqual(
      partialWorkflow.subscriptionRefreshFailure(for: record.id)?.credentialRollback,
      .partial(restored: otherPasswordRefs, failed: [fields.passwordRef]))
  }
}

/// Fails only when the existing password reference is touched during refresh
/// and again when the journal tries to restore its old value.
private final class SubscriptionRollbackCredentialStore: CredentialStoring {
  private var values: [CredentialReference: String] = [:]
  private var failingReference: CredentialReference?

  func save(_ secret: String, for reference: CredentialReference) throws {
    if reference == failingReference {
      throw CredentialStoreError.keychainStatus(errSecInternalError)
    }
    values[reference] = secret
  }

  func secret(for reference: CredentialReference) throws -> String? {
    values[reference]
  }

  func delete(_ reference: CredentialReference) throws {
    values.removeValue(forKey: reference)
  }

  func failSave(for reference: CredentialReference) {
    failingReference = reference
  }
}

/// 可门控获取缝：让第一次刷新停在 fetch 内部，验证并发守卫。fetch 在协作
/// 线程池上阻塞等待放行信号，不占用 MainActor。
final class GatedFetcher: SubscriptionFetching, @unchecked Sendable {
  private let lock = NSLock()
  private let release = DispatchSemaphore(value: 0)
  private var count = 0
  private var entered = false

  var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return count
  }

  var didEnterFetch: Bool {
    lock.lock()
    defer { lock.unlock() }
    return entered
  }

  func fetch(_ url: URL) async throws -> Data {
    lock.lock()
    count += 1
    entered = true
    lock.unlock()
    _ = release.wait(timeout: .now() + 5)
    return SubscriptionDocs.flat(serverCount: 0)
  }

  func releaseAll() {
    release.signal()
  }
}

/// SIP-008 文档夹具（订阅工作流语义测试）。
enum SubscriptionDocs {
  private static let stableServerA = "aaaaaaaa-0000-4000-8000-00000000000a"
  private static let stableServerB = "bbbbbbbb-0000-4000-8000-00000000000b"

  static func serverJSON(id: String, address: String, port: Int, remark: String) -> String {
    """
    {"id": "\(id)", "remarks": "\(remark)", "server": "\(address)", "server_port": \(port), \
    "password": "pw", "method": "aes-256-gcm"}
    """
  }

  static func flat(serverCount: Int) -> Data {
    guard serverCount > 0 else {
      return Data(#"{"version": 1, "servers": []}"#.utf8)
    }
    let servers = (1...serverCount).map {
      serverJSON(
        id: String(format: "%08x-0000-4000-8000-%012d", $0, $0), address: "203.0.113.\($0)",
        port: 8388 + $0, remark: "节点 \($0)")
    }.joined(separator: ",")
    return Data(
      """
      {"version": 1, "servers": [\(servers)]}
      """.utf8)
  }

  /// 根分组 [嵌套组 Japan(→b), 服务器 a]；稳定 UUID a/b。
  static func tree() -> Data {
    Data(
      """
      {"version": 1,
       "servers": [
         {"id": "aaaaaaaa-0000-4000-8000-00000000000a", "remarks": "香港 01", "server": "203.0.113.1", "server_port": 8388, "password": "pa", "method": "aes-256-gcm"},
         {"id": "bbbbbbbb-0000-4000-8000-00000000000b", "remarks": "日本 02", "server": "203.0.113.2", "server_port": 8389, "password": "pb", "method": "aes-256-gcm"}],
       "x_shadowsocksx_ng": {"schema_version": 1, "root_group_id": "root",
         "groups": [
           {"id": "root", "name": "Example subscription", "children": [
             {"type": "group", "id": "jp"}, {"type": "server", "id": "aaaaaaaa-0000-4000-8000-00000000000a"}]},
           {"id": "jp", "name": "Japan", "children": [
             {"type": "server", "id": "bbbbbbbb-0000-4000-8000-00000000000b"}]}]}}
      """.utf8)
  }

  /// 远端改名 + b 移到根 + 重排：[b, Japan(空)]，a 改名留在 Japan。
  static func treeRenamedAndReordered() -> Data {
    Data(
      """
      {"version": 1,
       "servers": [
         {"id": "aaaaaaaa-0000-4000-8000-00000000000a", "remarks": "香港 01（新名）", "server": "203.0.113.1", "server_port": 8388, "password": "pa", "method": "aes-256-gcm"},
         {"id": "bbbbbbbb-0000-4000-8000-00000000000b", "remarks": "日本 02", "server": "203.0.113.2", "server_port": 8389, "password": "pb", "method": "aes-256-gcm"}],
       "x_shadowsocksx_ng": {"schema_version": 1, "root_group_id": "root",
         "groups": [
           {"id": "root", "name": "Example subscription", "children": [
             {"type": "server", "id": "bbbbbbbb-0000-4000-8000-00000000000b"},
             {"type": "group", "id": "jp"}]},
           {"id": "jp", "name": "Japan", "children": [
             {"type": "server", "id": "aaaaaaaa-0000-4000-8000-00000000000a"}]}]}}
      """.utf8)
  }

  static func duplicateIDs() -> Data {
    let server = serverJSON(id: stableServerA, address: "203.0.113.1", port: 8388, remark: "x")
    let duplicate = serverJSON(id: stableServerA, address: "203.0.113.2", port: 9999, remark: "y")
    return Data(
      """
      {"version": 1, "servers": [\(server), \(duplicate)]}
      """.utf8)
  }

  static func invalidRecord() -> Data {
    Data(
      """
      {"version": 1, "servers": [{"id": "\(stableServerA)", "server": "203.0.113.1", "server_port": 0, "password": "p", "method": "m"}]}
      """.utf8)
  }

  static func idLess(port: Int = 8388) -> Data {
    Data(
      """
      {"version": 1, "servers": [{"server": "203.0.113.5", "server_port": \(port), "password": "p", "method": "m", "remarks": "无名"}]}
      """.utf8)
  }

  static func cycleExtension() -> Data {
    Data(
      """
      {"version": 1,
       "servers": [
         {"id": "\(stableServerA)", "server": "203.0.113.1", "server_port": 8388, "password": "pa", "method": "m"},
         {"id": "\(stableServerB)", "server": "203.0.113.2", "server_port": 8389, "password": "pb", "method": "m"}],
       "x_shadowsocksx_ng": {"schema_version": 1, "root_group_id": "root",
         "groups": [
           {"id": "root", "name": "R", "children": [{"type": "group", "id": "x"}]},
           {"id": "x", "name": "X", "children": [{"type": "group", "id": "root"}]}]}}
      """.utf8)
  }
}
