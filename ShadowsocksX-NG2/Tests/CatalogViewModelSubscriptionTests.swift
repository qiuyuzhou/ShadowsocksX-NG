import XCTest

@testable import ShadowsocksX_NG2

/// 订阅端到端语义（issue #35 验收）：创建门禁、刷新失败保留快照、overlay 与
/// 身份连续性、URL 编辑保身份、删除递归清除、UI 数据面与 postCommit 接线。
/// 获取走 FakeSubscriptionFetcher（传输侧契约在 SubscriptionFetcherTests）。
@MainActor
final class CatalogViewModelSubscriptionTests: XCTestCase {
  private var workDir: URL!
  private var fileURL: URL!
  private var credentials: InMemoryCredentialStore!
  private var fetcher: FakeSubscriptionFetcher!
  private var viewModel: CatalogViewModel!
  private var commitCounter: CommitCounter!

  override func setUp() async throws {
    try await super.setUp()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("subscription-vm-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    fileURL = workDir.appendingPathComponent("catalog.json")
    credentials = InMemoryCredentialStore()
    commitCounter = CommitCounter()
    fetcher = FakeSubscriptionFetcher(behavior: .success(SubscriptionDocs.flat(serverCount: 1)))
    viewModel = makeViewModel()
  }

  override func tearDown() async throws {
    try? FileManager.default.removeItem(at: workDir)
    try await super.tearDown()
  }

  private func makeViewModel() -> CatalogViewModel {
    let model = CatalogViewModel(
      fileStore: CatalogFileStore(fileURL: fileURL),
      credentials: credentials,
      plugins: NoManagedPluginProvider())
    model.subscriptionFetcher = fetcher!
    let counter = commitCounter!
    model.postCommit = { await counter.increment() }
    return model
  }

  // MARK: 文档夹具（稳定 UUID 服务器 a/b + 可选扩展树）

  /// 订阅身份是创建时新生成的 UUID，服务器作用域 ID 前缀随机；按文档稳定
  /// ID 后缀查找。
  private func serverID(withSuffix suffix: String) -> NodeID? {
    viewModel.catalog.entries.keys.first { $0.rawValue.hasSuffix(suffix) }
  }

  private var serverAID: NodeID {
    NodeID(
      rawValue: (serverID(withSuffix: "id:aaaaaaaa-0000-4000-8000-00000000000a"))?.rawValue
        ?? "missing-a")
  }

  private var serverBID: NodeID {
    NodeID(
      rawValue: (serverID(withSuffix: "id:bbbbbbbb-0000-4000-8000-00000000000b"))?.rawValue
        ?? "missing-b")
  }

  /// b 移到根 + a 改名 + 重排（远端改名/移动/排序跟随的对照文档）。
  private var treeDoc: Data { SubscriptionDocs.tree() }
  private var changedTreeDoc: Data { SubscriptionDocs.treeRenamedAndReordered() }

  // MARK: 创建门禁

  func testCreateRequiresHTTPSURL() async {
    for bad in ["http://example.com/sub.json", "ftp://x/y", "不是 URL", "https://"] {
      do {
        _ = try await viewModel.createSubscription(urlString: bad)
        XCTFail("「\(bad)」应被拒绝")
      } catch {
        XCTAssertEqual(error as? SubscriptionFormError, .invalidURL)
      }
    }
    XCTAssertTrue(viewModel.subscriptions.isEmpty, "创建失败不留半成品")
    XCTAssertTrue(viewModel.catalog.isEmpty)
  }

  func testCreateAddsRecordEmptyGroupAndRefreshes() async throws {
    fetcher = FakeSubscriptionFetcher(behavior: .success(treeDoc))
    viewModel = makeViewModel()

    let record = try await viewModel.createSubscription(
      urlString: "https://provider.example.com/sub.json")

    XCTAssertEqual(record.id, viewModel.subscriptions.first?.id)
    XCTAssertEqual(fetcher.lastURL?.host, "provider.example.com", "创建即首次刷新")
    let group = try XCTUnwrap(viewModel.entry(for: record.groupID))
    guard case .group(let fields) = group.kind else { return XCTFail("固定分组应存在") }
    XCTAssertEqual(fields.name, "Example subscription", "名称跟随远端根分组")
    XCTAssertTrue(viewModel.catalog.rootChildren.contains(record.groupID), "固定分组挂目录根")
    guard case .succeeded = viewModel.subscriptions[0].status else {
      return XCTFail("首次刷新成功应记成功态")
    }
  }

  func testFirstRefreshFailureLeavesEmptyGroupWithFailedStatus() async throws {
    fetcher = FakeSubscriptionFetcher(
      behavior: .failure(.transport(detail: "URLError.timedOut")))
    viewModel = makeViewModel()

    let created = try await viewModel.createSubscription(
      urlString: "https://provider.example.com/s.json")

    XCTAssertNotNil(viewModel.entry(for: created.groupID), "首刷失败仍留空分组")
    XCTAssertEqual(
      viewModel.displayName(for: created.groupID), "provider.example.com", "空分组以 host 兜底")
    guard case .failed(_, let reason) = viewModel.subscriptions[0].status else {
      return XCTFail("首刷失败应记失败态")
    }
    XCTAssertTrue(reason.contains("URLError.timedOut"))
    XCTAssertFalse(reason.contains("provider.example.com"), "失败原因不得携带订阅地址")
  }

  // MARK: 失败保留语义

  func testFailedRefreshKeepsSnapshotAndStatus() async throws {
    fetcher = FakeSubscriptionFetcher(behavior: .success(treeDoc))
    viewModel = makeViewModel()
    let record = try await viewModel.createSubscription(urlString: "https://p.example.com/s.json")
    let commitsBefore = await commitCounter.count

    fetcher = FakeSubscriptionFetcher(behavior: .failure(.httpStatus(code: 503)))
    viewModel.subscriptionFetcher = fetcher
    await viewModel.refreshSubscription(record.id)

    // 快照原样保留。
    XCTAssertNotNil(viewModel.entry(for: serverAID))
    XCTAssertNotNil(viewModel.entry(for: serverBID))
    XCTAssertEqual(viewModel.displayName(for: serverAID), "香港 01")
    // 状态点名失败且原因脱敏。
    guard case .failed(_, let reason) = viewModel.subscriptions[0].status else {
      return XCTFail("应记失败态")
    }
    XCTAssertTrue(reason.contains("503"))
    // 仅状态提交了一次（快照未动）。
    let commitsAfter = await commitCounter.count
    XCTAssertEqual(commitsAfter - commitsBefore, 1)
  }

  func testDecodeAndSchemaFailuresMarkFailedWithoutTouchingSnapshot() async throws {
    let record = try await seedSuccessfulSubscription()

    for behavior in [
      FakeSubscriptionFetcher.Behavior.failure(.contentType(received: "text/plain")),
      FakeSubscriptionFetcher.Behavior.success(Data("not json".utf8)),
      FakeSubscriptionFetcher.Behavior.success(Data(#"{"version": 9, "servers": []}"#.utf8)),
    ] {
      let snapshotBefore = viewModel.catalog
      viewModel.subscriptionFetcher = FakeSubscriptionFetcher(behavior: behavior)
      await viewModel.refreshSubscription(record.id)

      guard case .failed(_, let reason) = viewModel.subscriptions[0].status else {
        return XCTFail("应记失败态：\(behavior)")
      }
      XCTAssertFalse(reason.isEmpty)
      XCTAssertEqual(viewModel.catalog, snapshotBefore, "解析类失败不动快照")
      // 失败原因不携带订阅 URL。
      XCTAssertFalse(reason.lowercased().contains("p.example.com"))
    }
  }

  func testDuplicateIDFailureKeepsSnapshot() async throws {
    let record = try await seedSuccessfulSubscription()
    let snapshotBefore = viewModel.catalog

    viewModel.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.duplicateIDs()))
    await viewModel.refreshSubscription(record.id)

    guard case .failed(_, let reason) = viewModel.subscriptions[0].status else {
      return XCTFail("应记失败态")
    }
    XCTAssertTrue(reason.contains("重复"), "点名重复 ID：\(reason)")
    XCTAssertEqual(viewModel.catalog, snapshotBefore)
  }

  func testRecordValidationFailureKeepsSnapshot() async throws {
    let record = try await seedSuccessfulSubscription()
    let snapshotBefore = viewModel.catalog

    viewModel.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.invalidRecord()))
    await viewModel.refreshSubscription(record.id)

    guard case .failed(_, let reason) = viewModel.subscriptions[0].status else {
      return XCTFail("应记失败态")
    }
    XCTAssertTrue(reason.contains("server_port"), "点名无效字段：\(reason)")
    XCTAssertEqual(viewModel.catalog, snapshotBefore)
  }

  // MARK: 空快照与扁平回退

  func testEmptySnapshotIsSuccessAndClearsSubtree() async throws {
    let record = try await seedSuccessfulSubscription()

    viewModel.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.flat(serverCount: 0)))
    await viewModel.refreshSubscription(record.id)

    let group = try viewModel.entry(for: record.groupID)
    guard case .group(let fields) = group?.kind else { return XCTFail("固定分组应保留") }
    XCTAssertTrue(fields.children.isEmpty, "合法空快照清空子树")
    guard case .succeeded = viewModel.subscriptions[0].status else {
      return XCTFail("空快照按成功处理")
    }
  }

  func testCycleDocumentFallsBackToFlatAndSucceeds() async throws {
    let record = try await seedSuccessfulSubscription()

    viewModel.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.cycleExtension()))
    await viewModel.refreshSubscription(record.id)

    guard case .group(let fields) = viewModel.entry(for: record.groupID)?.kind else {
      return XCTFail("固定分组应存在")
    }
    XCTAssertEqual(fields.children.count, 2, "回退扁平：标准服务器直接进固定分组")
    XCTAssertEqual(fields.name, "p.example.com", "扁平回退以 host 兜底名称")
    guard case .succeeded = viewModel.subscriptions[0].status else {
      return XCTFail("回退扁平仍是成功刷新")
    }
  }

  // MARK: 身份连续性

  func testRemoteRenameMoveReorderFollowsWithoutLocalOverlay() async throws {
    fetcher = FakeSubscriptionFetcher(behavior: .success(treeDoc))
    viewModel = makeViewModel()
    let record = try await viewModel.createSubscription(urlString: "https://p.example.com/s.json")
    viewModel.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(changedTreeDoc))
    await viewModel.refreshSubscription(record.id)

    // 身份不变；名称/位置/顺序跟随远端。
    XCTAssertEqual(viewModel.displayName(for: serverAID), "香港 01（新名）")
    guard case .group(let fields) = viewModel.entry(for: record.groupID)?.kind else {
      return XCTFail("固定分组应存在")
    }
    let japanGroupID = try XCTUnwrap(
      viewModel.catalog.entries.keys.first { $0.rawValue.hasSuffix("g:jp") })
    XCTAssertEqual(fields.children, [serverBID, japanGroupID], "远端排序跟随")
  }

  func testIdLessServerContinuityOnlyForExactMatch() async throws {
    fetcher = FakeSubscriptionFetcher(behavior: .success(SubscriptionDocs.idLess()))
    viewModel = makeViewModel()
    let record = try await viewModel.createSubscription(urlString: "https://p.example.com/s.json")
    let serverID = try XCTUnwrap(onlyServerChildID(ofGroup: record.groupID))
    // 完全相同记录 → 身份延续。
    await viewModel.refreshSubscription(record.id)
    XCTAssertEqual(onlyServerChildID(ofGroup: record.groupID), serverID)

    // 端口变化 → 新身份：旧节点删除（无墓碑）。
    viewModel.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.idLess(port: 9999)))
    await viewModel.refreshSubscription(record.id)
    XCTAssertNil(viewModel.entry(for: serverID), "无稳定 ID 且记录变化即不同节点")
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
    viewModel.subscriptionFetcher = failing
    try await viewModel.editSubscriptionURL(
      record.id, urlString: "https://other.example.com/v2.json")
    XCTAssertEqual(viewModel.subscriptions[0].id, originalRecordID, "订阅身份保留")
    guard case .failed = viewModel.subscriptions[0].status else {
      return XCTFail("新地址失败应记失败态")
    }
    XCTAssertEqual(failing.lastURL?.host, "other.example.com")
    XCTAssertNotNil(viewModel.entry(for: serverAID), "失败保留最后成功快照")

    // 新地址成功：同一身份命名空间下应用新内容。
    viewModel.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .success(SubscriptionDocs.flat(serverCount: 1)))
    await viewModel.refreshSubscription(record.id)
    XCTAssertEqual(viewModel.subscriptions[0].groupID, originalGroupID)
    guard case .succeeded = viewModel.subscriptions[0].status else {
      return XCTFail("换址成功应记成功态，实际 \(viewModel.subscriptions[0].status)")
    }
    XCTAssertEqual(viewModel.catalog.rootChildren.count, 1)
  }

  func testRemoveSubscriptionClearsRecordSubtreeCredentialsAndSelection() async throws {
    let record = try await seedSuccessfulSubscription()
    viewModel.selectedNodeID = serverAID
    let passwordRef = try XCTUnwrap(serverFields(of: serverAID)).passwordRef
    let commitsBefore = await commitCounter.count

    try await viewModel.removeSubscription(record.id)

    XCTAssertTrue(viewModel.subscriptions.isEmpty, "订阅记录移除")
    XCTAssertNil(viewModel.entry(for: record.groupID), "固定分组递归清除")
    XCTAssertNil(viewModel.entry(for: serverAID))
    XCTAssertNil(viewModel.entry(for: serverBID))
    XCTAssertNil(viewModel.selectedNodeID, "选中节点随子树清除")
    XCTAssertNil(try credentials.secret(for: passwordRef), "远端成员凭据一并清理")
    XCTAssertNil(try credentials.secret(for: record.urlRef), "订阅 URL 凭据一并清理")
    let commitsAfter = await commitCounter.count
    XCTAssertEqual(commitsAfter - commitsBefore, 1, "删除经 postCommit 触发活动目标重展开接线")
  }

  // MARK: 批量刷新与持久化

  func testRefreshAllRefreshesEverySubscription() async throws {
    _ = try await seedSuccessfulSubscription()
    _ = try await createOnly(urlString: "https://q.example.com/t.json")
    let requestsBefore = fetcher.requestCount
    let commitsBefore = await commitCounter.count

    await viewModel.refreshAllSubscriptions()

    XCTAssertEqual(fetcher.requestCount - requestsBefore, 2, "每个订阅各刷一次")
    for record in viewModel.subscriptions {
      guard case .succeeded = record.status else {
        return XCTFail("全部订阅都应记成功态：\(record.id)")
      }
    }
    let commitsAfter = await commitCounter.count
    XCTAssertEqual(commitsAfter - commitsBefore, 2)
  }

  func testSubscriptionsPersistAcrossViewModelReload() async throws {
    let record = try await seedSuccessfulSubscription()

    let reloaded = CatalogViewModel(
      fileStore: CatalogFileStore(fileURL: fileURL),
      credentials: credentials,
      plugins: NoManagedPluginProvider())
    XCTAssertEqual(reloaded.subscriptions.count, 1)
    XCTAssertEqual(reloaded.subscriptions[0].id, record.id)
    guard case .succeeded = reloaded.subscriptions[0].status else {
      return XCTFail("刷新状态跨持久化保留")
    }
    XCTAssertNotNil(reloaded.entry(for: serverAID))
  }

  // MARK: 卡片数据面

  func testSubscriptionCardReflectsStatusAndCounts() async throws {
    _ = try await seedSuccessfulSubscription()
    let record = try XCTUnwrap(viewModel.subscriptions.first)

    let healthy = viewModel.subscriptionCard(for: record)
    XCTAssertEqual(healthy.name, "Example subscription")
    XCTAssertEqual(healthy.host, "p.example.com", "卡片展示 host，不展示完整 URL")
    XCTAssertEqual(healthy.statusText, "正常")
    XCTAssertEqual(healthy.serverCount, 2)
    XCTAssertFalse(healthy.isFailed)

    viewModel.subscriptionFetcher = FakeSubscriptionFetcher(
      behavior: .failure(.transport(detail: "URLError.cannotConnectToHost")))
    await viewModel.refreshSubscription(record.id)

    let current = try XCTUnwrap(viewModel.subscriptions.first)
    let failed = viewModel.subscriptionCard(for: current)
    XCTAssertTrue(failed.isFailed)
    XCTAssertEqual(failed.statusText, "刷新失败")
    XCTAssertTrue(failed.statusDetail?.contains("URLError.cannotConnectToHost") == true)
    XCTAssertEqual(failed.serverCount, 2, "失败保留最后成功的服务器数")
  }

  // MARK: 并发守卫

  func testConcurrentRefreshOnSameSubscriptionDoesNotReenter() async throws {
    let record = try await seedSuccessfulSubscription()
    let gated = GatedFetcher()
    viewModel.subscriptionFetcher = gated

    async let first: Void = viewModel.refreshSubscription(record.id)
    // 轮询而非阻塞等待：主线程阻塞会饿死继承 MainActor 的 async let 子任务。
    while !gated.didEnterFetch {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    await viewModel.refreshSubscription(record.id)

    XCTAssertEqual(gated.requestCount, 1, "同一订阅刷新进行中不重入")
    gated.releaseAll()
    await first
    XCTAssertTrue(viewModel.inFlightRefreshIDs.isEmpty, "完成后守卫释放")
  }

  // MARK: 夹具与辅助

  private func onlyServerChildID(ofGroup groupID: NodeID) -> NodeID? {
    guard case .group(let fields) = viewModel.entry(for: groupID)?.kind,
      fields.children.count == 1,
      case .server = viewModel.entry(for: fields.children[0])?.kind
    else { return nil }
    return fields.children[0]
  }

  private func serverFields(of id: NodeID) -> ServerFields? {
    guard case .server(let fields) = viewModel.entry(for: id)?.kind else { return nil }
    return fields
  }

  /// 建一个「创建 + 首刷成功（tree 文档，服务器 a/b）」的订阅。
  private func seedSuccessfulSubscription() async throws -> SubscriptionRecord {
    fetcher = FakeSubscriptionFetcher(behavior: .success(SubscriptionDocs.tree()))
    viewModel = makeViewModel()
    return try await createOnly(urlString: "https://p.example.com/s.json")
  }

  private func createOnly(urlString: String) async throws -> SubscriptionRecord {
    try await viewModel.createSubscription(urlString: urlString)
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

/// SIP-008 文档夹具（订阅 VM 语义测试）。
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
