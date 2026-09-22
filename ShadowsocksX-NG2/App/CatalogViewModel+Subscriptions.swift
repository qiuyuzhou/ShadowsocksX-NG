import Foundation

/// 订阅生命周期（spec #21 D4，issue #35）：粘贴 HTTPS URL 创建、单个/全部
/// 立即更新、编辑 URL（保留身份）、删除（递归清除）。刷新 = 完整获取、解析、
/// 校验后同文档原子提交快照与刷新状态；任何失败保留最后成功快照、活动目标与
/// 运行状态，仅标记来源失败。每次提交都触发 postCommit
/// 重展开（订阅子树变更 → 活动目标原子跟随或清除停止）。
extension CatalogViewModel {
  /// 创建订阅：校验 HTTPS URL → 落订阅记录与空固定分组 → 立即首次刷新。
  /// 首次刷新失败留空分组加错误态（状态在刷新内标记，创建本身总是成功）。
  @discardableResult
  func createSubscription(urlString: String) async throws -> SubscriptionRecord {
    let url = try Self.validatedSubscriptionURL(urlString)
    let record = SubscriptionRecord(
      id: .fresh(),
      groupID: .fresh(),
      urlRef: .fresh(),
      status: .never)
    try credentials.save(url.absoluteString, for: record.urlRef)
    try await commitDocument { catalog, subscriptions in
      // 固定分组挂在目录根（CONTEXT.md「Subscription group」）；名称以 host
      // 兜底，首次成功刷新后跟随远端。
      try catalog.addGroup(url.host ?? "", source: .subscription, id: record.groupID)
      subscriptions.append(record)
    }
    await refreshSubscription(record.id)
    // 返回刷新后的最新记录（状态在首次刷新中落定）。
    return subscriptions.first(where: { $0.id == record.id }) ?? record
  }

  /// 立即更新单个订阅。不抛错：失败标记到订阅状态（无静默，有呈现）。
  /// 同一订阅不重入：进行中的刷新期间重复触发直接跳过。
  func refreshSubscription(_ id: NodeID) async {
    guard !inFlightRefreshIDs.contains(id),
      subscriptions.contains(where: { $0.id == id })
    else { return }
    setSubscriptionRefreshInFlight(id, true)
    defer { setSubscriptionRefreshInFlight(id, false) }
    do {
      try await performRefresh(id)
    } catch is CancellationError {
      // 取消不构成失败：快照与状态都不动。
    } catch {
      await markRefreshFailed(subscriptionID: id, reason: error.presentableMessage)
    }
  }

  /// 立即更新全部订阅（逐个顺序执行；单个失败不影响其余）。
  func refreshAllSubscriptions() async {
    for record in subscriptions {
      await refreshSubscription(record.id)
    }
  }

  /// 编辑订阅 URL：同一凭据引用覆盖写，订阅/固定分组/远端身份命名空间全部
  /// 保留；最后成功快照保留到新 URL 刷新成功，随后立即刷新。
  func editSubscriptionURL(_ id: NodeID, urlString: String) async throws {
    guard subscriptions.contains(where: { $0.id == id }) else {
      throw SubscriptionFormError.notFound
    }
    let url = try Self.validatedSubscriptionURL(urlString)
    guard let record = subscriptions.first(where: { $0.id == id }) else {
      throw SubscriptionFormError.notFound
    }
    try credentials.save(url.absoluteString, for: record.urlRef)
    await refreshSubscription(record.id)
  }

  /// 删除订阅：递归清除订阅源、固定分组与远端成员；活动目标
  /// 的清除与代理停止由 postCommit 的既有激活语义处理（无静默回退）。
  func removeSubscription(_ id: NodeID) async throws {
    guard let record = subscriptions.first(where: { $0.id == id }) else {
      throw SubscriptionFormError.notFound
    }
    var removedEntries: [CatalogEntry] = []
    try await commitDocument { catalog, subscriptions in
      removedEntries = try catalog.removeSubscriptionSubtree(of: record.groupID)
      subscriptions.removeAll { $0.id == id }
    }
    var refs = [record.urlRef]
    for entry in removedEntries {
      if case .server(let fields) = entry.kind {
        refs.append(fields.passwordRef)
        if let optionsRef = fields.pluginOptionsRef { refs.append(optionsRef) }
      }
    }
    for ref in refs {
      try? credentials.delete(ref)
    }
    if let selection = selectedNodeID,
      removedEntries.contains(where: { $0.id == selection })
    {
      selectedNodeID = nil
    }
  }

  // MARK: - 卡片呈现

  /// 订阅卡片五要素（D11）：名称、URL host、状态、上次刷新、服务器数。
  func subscriptionCard(for record: SubscriptionRecord) -> SubscriptionCardInfo {
    let host = subscriptionURL(for: record)?.host ?? ""
    let subtree = (try? catalog.subscriptionSubtree(of: record.groupID)) ?? []
    let serverCount = subtree.reduce(0) { count, entry in
      if case .server = entry.kind { return count + 1 }
      return count
    }
    let name = displayName(for: record.groupID)

    switch record.status {
    case .never:
      return SubscriptionCardInfo(
        name: name, host: host,
        statusText: "尚未刷新", statusDetail: nil,
        lastRefreshText: "尚未刷新", serverCount: serverCount, isFailed: false)
    case .succeeded(let date):
      return SubscriptionCardInfo(
        name: name, host: host,
        statusText: "正常", statusDetail: nil,
        lastRefreshText: date.formatted(date: .abbreviated, time: .shortened),
        serverCount: serverCount, isFailed: false)
    case .failed(let date, let reason):
      return SubscriptionCardInfo(
        name: name, host: host,
        statusText: "刷新失败", statusDetail: reason,
        lastRefreshText: date.formatted(date: .abbreviated, time: .shortened),
        serverCount: serverCount, isFailed: true)
    }
  }

  // MARK: - 刷新内核

  /// 完整获取 → 解析校验 → 凭据解析 → 原子提交快照与成功状态。
  private func performRefresh(_ id: NodeID) async throws {
    guard let record = subscriptions.first(where: { $0.id == id }) else { return }
    // 缺凭据是命名失败（区别于地址格式无效），不静默当作空 URL。
    guard let urlString = try credentials.secret(for: record.urlRef) else {
      throw CredentialStoreError.keychainStatus(errSecItemNotFound)
    }
    let url = try Self.validatedSubscriptionURL(urlString)
    let data = try await subscriptionFetcher.fetch(url)
    let snapshot = try SubscriptionDocumentParser.parse(data, subscriptionID: record.id)
    try await commitSnapshot(snapshot, record: record, fallbackName: url.host ?? "")
  }

  private func commitSnapshot(
    _ snapshot: SubscriptionSnapshot, record: SubscriptionRecord, fallbackName: String
  ) async throws {
    var removedServers: [CatalogEntry] = []
    var credentialJournal = CredentialWriteJournal(credentials: credentials)
    do {
      try await commitDocument { catalog, subscriptions in
        // 凭据引用按节点身份复用：延续节点覆盖写秘密，不新增孤儿引用；
        // journal 保证快照提交失败时恢复旧秘密。
        var reusedRefs: [NodeID: ServerCredentialRefs] = [:]
        for entry in (try? catalog.subscriptionSubtree(of: record.groupID)) ?? [] {
          if case .server(let fields) = entry.kind {
            reusedRefs[entry.id] = ServerCredentialRefs(
              password: fields.passwordRef, options: fields.pluginOptionsRef)
          }
        }
        let resolved = try Self.resolveCredentials(
          snapshot.root, catalogGroupID: record.groupID, reuse: reusedRefs,
          journal: &credentialJournal)
        let name = snapshot.root.name.isEmpty ? fallbackName : snapshot.root.name
        let document = CatalogSubscriptionSnapshot(name: name, root: resolved)
        removedServers = try catalog.applySubscriptionSnapshot(document, into: record.groupID)
        if let index = subscriptions.firstIndex(where: { $0.id == record.id }) {
          subscriptions[index].status = .succeeded(at: Date())
        }
      }
    } catch {
      credentialJournal.rollback()
      throw error
    }
    // 被移除节点的凭据引用不会被新树复用（身份已不在），提交成功后清理。
    for entry in removedServers {
      if case .server(let fields) = entry.kind {
        try? credentials.delete(fields.passwordRef)
        if let optionsRef = fields.pluginOptionsRef { try? credentials.delete(optionsRef) }
      }
    }
  }

  private func markRefreshFailed(subscriptionID: NodeID, reason: String) async {
    try? await commitDocument { _, subscriptions in
      if let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
        subscriptions[index].status = .failed(at: Date(), reason: reason)
      }
    }
  }

  /// 订阅 URL 的只读解析（卡片只展示 host，完整地址不出凭据存储）。
  private func subscriptionURL(for record: SubscriptionRecord) -> URL? {
    guard let stored = ((try? credentials.secret(for: record.urlRef)) ?? nil) else {
      return nil
    }
    return URL(string: stored)
  }

  /// 明文快照 → 目录形态：密码与插件参数写入凭据存储、目录持引用。
  /// 延续节点复用既有引用（覆盖写），新节点分配新引用。
  private static func resolveCredentials(
    _ group: SubscriptionSnapshot.Group,
    catalogGroupID: NodeID,
    reuse: [NodeID: ServerCredentialRefs],
    journal: inout CredentialWriteJournal
  ) throws -> CatalogSubscriptionSnapshot.Group {
    var children: [CatalogSubscriptionSnapshot.Child] = []
    for child in group.children {
      switch child {
      case .server(let leaf):
        let existing = reuse[leaf.id]
        let passwordRef = existing?.password ?? .fresh()
        try journal.save(leaf.record.password, for: passwordRef)
        var optionsRef: CredentialReference?
        if let options = leaf.record.pluginOptions, !options.isEmpty {
          let ref = existing?.options ?? .fresh()
          try journal.save(options, for: ref)
          optionsRef = ref
        }
        children.append(
          .server(
            CatalogSubscriptionSnapshot.ServerLeaf(
              id: leaf.id,
              fields: ServerFields(
                address: leaf.record.address,
                port: leaf.record.port,
                encryptionMethod: leaf.record.encryptionMethod,
                passwordRef: passwordRef,
                remark: leaf.record.remark,
                pluginProgram: leaf.record.pluginProgram,
                pluginOptionsRef: optionsRef))))
      case .group(let nested):
        children.append(
          .group(
            try resolveCredentials(
              nested, catalogGroupID: nested.id, reuse: reuse, journal: &journal)))
      }
    }
    return CatalogSubscriptionSnapshot.Group(
      id: catalogGroupID, name: group.name, children: children)
  }

  /// 订阅地址门禁：必须是带主机的 HTTPS URL（宽松模式永不提供）。
  static func validatedSubscriptionURL(_ string: String) throws -> URL {
    let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let url = URL(string: trimmed),
      url.scheme?.lowercased() == "https",
      url.host != nil
    else {
      throw SubscriptionFormError.invalidURL
    }
    return url
  }
}

/// 一台服务器叶子的凭据引用对（密码 + 可选插件参数）。
struct ServerCredentialRefs: Sendable {
  var password: CredentialReference
  var options: CredentialReference?
}

/// 订阅刷新期间的凭据写入日志。目录文件只有在全部写入成功后才替换；如果
/// 任何凭据或目录写入失败，则恢复刷新前的每个引用，避免旧快照的秘密被覆盖。
private struct CredentialWriteJournal {
  private struct OriginalValue {
    let secret: String?
  }

  let credentials: CredentialStoring
  private var originals: [CredentialReference: OriginalValue] = [:]

  init(credentials: CredentialStoring) {
    self.credentials = credentials
  }

  mutating func save(_ secret: String, for reference: CredentialReference) throws {
    if originals[reference] == nil {
      originals[reference] = OriginalValue(secret: try credentials.secret(for: reference))
    }
    try credentials.save(secret, for: reference)
  }

  func rollback() {
    for (reference, original) in originals {
      if let secret = original.secret {
        try? credentials.save(secret, for: reference)
      } else {
        try? credentials.delete(reference)
      }
    }
  }
}

/// 订阅表单级失败（URL 门禁、订阅不存在）；获取/解析失败仍以原错误上抛。
enum SubscriptionFormError: Error, Equatable {
  case invalidURL
  case notFound
}

/// 订阅卡片呈现快照（由 CatalogViewModel 派生，issue #35 D11）。
struct SubscriptionCardInfo: Equatable {
  let name: String
  let host: String
  let statusText: String
  let statusDetail: String?
  let lastRefreshText: String
  let serverCount: Int
  let isFailed: Bool
}
