import Foundation

/// 订阅生命周期（spec #21 D4，issue #35/#41）：粘贴 HTTPS URL 创建、单个/全部
/// 立即更新、编辑 URL（保留身份）、删除（递归清除）。刷新 = 完整获取、解析、
/// 校验后同文档原子提交快照与刷新状态；任何失败保留最后成功快照、活动目标与
/// 运行状态，仅标记来源失败（story 27/28）。每次提交都经目录提交协调器异步
/// 触发运行时收敛（issue #40；订阅子树变更 → 活动目标原子跟随或清除停止）。
extension CatalogWorkflow {
  /// 创建订阅（story 24）：校验 HTTPS URL → 落订阅记录与空固定分组 → 立即
  /// 首次刷新。首次刷新失败留空分组加错误态（状态在刷新内标记，创建本身总是
  /// 成功）。返回订阅 summary（状态在首次刷新中落定）。
  @discardableResult
  func createSubscription(urlString: String) async throws -> SubscriptionSummary {
    let url = try Self.validatedSubscriptionURL(urlString)
    let record = SubscriptionRecord(
      id: .fresh(),
      groupID: .fresh(),
      urlRef: .fresh(),
      status: .never)
    try credentials.save(url.absoluteString, for: record.urlRef)
    do {
      try commitSubscriptionDocument { catalog, subscriptions in
        // 固定分组挂在目录根（CONTEXT.md「Subscription group」）；名称以 host
        // 兜底，首次成功刷新后跟随远端。
        try catalog.addGroup(url.host ?? "", source: .subscription, id: record.groupID)
        subscriptions.append(record)
      }
    } catch {
      try? credentials.delete(record.urlRef)
      throw error
    }
    await refreshSubscription(record.id)
    return subscriptions.first(where: { $0.id == record.id })
      ?? SubscriptionSummary(
        id: record.id, groupID: record.groupID, name: url.host ?? "",
        host: url.host ?? "", status: .never, serverCount: 0)
  }

  /// 立即更新单个订阅（story 26/27）。不抛错：失败标记到订阅状态（无静默，
  /// 有结构化状态可呈现）。同一订阅不重入：进行中的刷新期间重复触发直接跳过。
  func refreshSubscription(_ id: NodeID) async {
    guard !refreshingSubscriptionIDs.contains(id),
      subscriptions.contains(where: { $0.id == id })
    else { return }
    setRefreshInFlight(id, true)
    defer { setRefreshInFlight(id, false) }
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

  /// 编辑订阅 URL（story 25）：同一凭据引用覆盖写，订阅/固定分组/远端身份
  /// 命名空间全部保留；最后成功快照保留到新 URL 刷新成功，随后立即刷新。
  func editSubscriptionURL(_ id: NodeID, urlString: String) async throws {
    guard let record = subscriptionRecord(withID: id) else {
      throw SubscriptionFormError.notFound
    }
    let url = try Self.validatedSubscriptionURL(urlString)
    // 覆盖写同一引用；URL 编辑不落目录文档（引用与身份不变），新地址刷新
    // 成功才有新快照——写入失败不触碰目录状态。
    try credentials.save(url.absoluteString, for: record.urlRef)
    await refreshSubscription(record.id)
  }

  /// 删除订阅（story 30）：递归清除订阅源、固定分组与远端成员并清理凭据；
  /// 活动目标的清除与代理停止由 postCommit 的既有激活语义处理（无静默回退）。
  /// 返回被删身份集合供 UI 清除失效选择。
  func removeSubscription(_ id: NodeID) async throws -> RemovalOutcome {
    guard let record = subscriptionRecord(withID: id) else {
      throw SubscriptionFormError.notFound
    }
    var removedEntries: [CatalogEntry] = []
    try commitSubscriptionDocument { catalog, subscriptions in
      removedEntries = try catalog.removeSubscriptionSubtree(of: record.groupID)
      subscriptions.removeAll { $0.id == id }
    }
    for ref in [record.urlRef] + Self.credentialRefs(of: removedEntries) {
      try? credentials.delete(ref)
    }
    return RemovalOutcome(removedNodeIDs: Set(removedEntries.map(\.id)))
  }

  /// 编辑面预填用：读取订阅 URL 明文（story 11——仅用户显式编辑动作触发）。
  func subscriptionURL(for id: NodeID) throws -> String {
    guard let record = subscriptionRecord(withID: id) else {
      throw SubscriptionFormError.notFound
    }
    guard let stored = try credentials.secret(for: record.urlRef) else {
      throw CredentialStoreError.keychainStatus(errSecItemNotFound)
    }
    return stored
  }

  // MARK: - 刷新内核

  /// 完整获取 → 解析校验 → 凭据解析 → 原子提交快照与成功状态。
  private func performRefresh(_ id: NodeID) async throws {
    guard let record = subscriptionRecord(withID: id) else { return }
    // 缺凭据是命名失败（区别于地址格式无效），不静默当作空 URL。
    let urlString = try subscriptionURL(for: record.id)
    let url = try Self.validatedSubscriptionURL(urlString)
    let data = try await subscriptionFetcher.fetch(url)
    let snapshot = try SubscriptionDocumentParser.parse(data, subscriptionID: record.id)
    let summary =
      subscriptions.first(where: { $0.id == record.id })
      ?? SubscriptionSummary(
        id: record.id, groupID: record.groupID, name: "", host: "",
        status: record.status, serverCount: 0)
    try await commitSnapshot(snapshot, summary: summary, fallbackName: url.host ?? "")
  }

  private func commitSnapshot(
    _ snapshot: SubscriptionSnapshot, summary: SubscriptionSummary, fallbackName: String
  ) async throws {
    var removedServers: [CatalogEntry] = []
    var credentialJournal = CredentialWriteJournal(credentials: credentials)
    do {
      try commitSubscriptionDocument { [self] catalog, subscriptions in
        // 凭据引用按节点身份复用：延续节点覆盖写秘密，不新增孤儿引用；
        // journal 保证快照提交失败时恢复旧秘密（story 29）。
        var reusedRefs: [NodeID: ServerCredentialRefs] = [:]
        for entry in (try? catalog.subscriptionSubtree(of: summary.groupID)) ?? [] {
          if case .server(let fields) = entry.kind {
            reusedRefs[entry.id] = ServerCredentialRefs(
              password: fields.passwordRef, options: fields.pluginOptionsRef)
          }
        }
        let resolved = try Self.resolveCredentials(
          snapshot.root, catalogGroupID: summary.groupID, reuse: reusedRefs,
          journal: &credentialJournal)
        let name = snapshot.root.name.isEmpty ? fallbackName : snapshot.root.name
        let document = CatalogSubscriptionSnapshot(name: name, root: resolved)
        removedServers = try catalog.applySubscriptionSnapshot(document, into: summary.groupID)
        if let index = subscriptions.firstIndex(where: { $0.id == summary.id }) {
          subscriptions[index].status = .succeeded(at: Date())
        }
      }
    } catch {
      // story 29：尽力恢复旧秘密；typed outcome 的观测上提（经抛错或订阅
      // 状态）待候选 4 拆开订阅失败文案与持久化 schema 字段后再做。
      _ = credentialJournal.rollback()
      throw error
    }
    // 被移除节点的凭据引用不会被新树复用（身份已不在），提交成功后清理。
    for ref in Self.credentialRefs(of: removedServers) {
      try? credentials.delete(ref)
    }
  }

  /// 失败点名写入订阅状态。`reason` 是 Domain 持久化 schema 的字段（D5 脱敏、
  /// 不含订阅 URL），不是弹窗文案；其文案化沿用在同一 presentation 边缘的
  /// `Error.presentableMessage`，独立编译 target 拆分时随该边缘外移。
  private func markRefreshFailed(subscriptionID: NodeID, reason: String) async {
    try? commitSubscriptionDocument { _, subscriptions in
      if let index = subscriptions.firstIndex(where: { $0.id == subscriptionID }) {
        subscriptions[index].status = .failed(at: Date(), reason: reason)
      }
    }
  }

  /// 订阅原始记录查询（module 内部；投影不含凭据引用等原始形态）。
  private func subscriptionRecord(withID id: NodeID) -> SubscriptionRecord? {
    coordinator.committedSubscriptions.first { $0.id == id }
  }

  /// 订阅卡片 projection 推导（module 内部）：名称、URL host、结构化状态、
  /// 服务器数。
  static func subscriptionSummaries(
    _ records: [SubscriptionRecord],
    catalog: ConfigurationCatalog,
    credentials: CredentialStoring
  ) -> [SubscriptionSummary] {
    records.map { record in
      let host =
        (try? credentials.secret(for: record.urlRef))
        .flatMap { $0.flatMap(URL.init(string:)) }?.host ?? ""
      let subtree = (try? catalog.subscriptionSubtree(of: record.groupID)) ?? []
      let serverCount = subtree.reduce(0) { count, entry in
        if case .server = entry.kind { return count + 1 }
        return count
      }
      return SubscriptionSummary(
        id: record.id,
        groupID: record.groupID,
        name: catalog.entry(for: record.groupID)?.displayName ?? "",
        host: host,
        status: record.status,
        serverCount: serverCount)
    }
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
