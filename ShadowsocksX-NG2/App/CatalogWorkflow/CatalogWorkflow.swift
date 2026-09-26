import Combine
import Foundation

/// 目录工作流 module（issue #41，#49 深化为 application module）：主窗口与
/// 配置 UI 的唯一 UI-facing seam。隐藏配置目录、凭据存储、订阅快照、Legacy
/// 导入细节、持久化协调与运行时收敛，向 UI 提供不含秘密值的树/详情/订阅
/// projection、opaque 节点身份查询、typed command、typed error 与 structured
/// outcome。选择、pane、sheet、alert 等窗口状态仍由 UI 持有；本类不生成
/// 用户可见文案。
///
/// 内部沿用既有深 module：`ConfigurationCatalog` 的结构约束、
/// `ActivationStateMachine` 经 `CatalogCommitCoordinator` 的激活语义与目录
/// 持久化/runtime sync 协调，以及既有凭据、订阅获取与 Legacy 导入缝。
/// 「目录已提交」与「运行时已收敛」是分离的观察面（story 38/39）：提交在
/// 持久化成功即完成，`runtimeSync` 单独呈现收敛阶段，失败不回滚目录。
/// 实现 adapter 全部经组合根注入的 `CatalogWorkflowDependencies` 装配
/// （issue #49），本类不自行创建生产默认实现。
@MainActor
final class CatalogWorkflow: ObservableObject {
  /// 目录树 projection（侧栏、级联、移动目的地、删除确认共用）。
  @Published private(set) var tree: CatalogTreeSnapshot
  /// 订阅卡片 projection（非敏感）。
  @Published private(set) var subscriptions: [SubscriptionSummary] = []
  /// 正在刷新的订阅身份（并发守卫的只读观察面）。
  @Published private(set) var refreshingSubscriptionIDs: Set<NodeID> = []
  /// 最近一次订阅刷新失败的 transient projection。这里保留完整凭据回滚
  /// outcome；持久化目录只保存安全的 typed failure facts。
  @Published private(set) var subscriptionRefreshFailures:
    [NodeID: SubscriptionRefreshFailureResult] = [:]
  /// 最近一次提交的运行时收敛阶段（与目录提交成功分离，story 38）。
  @Published private(set) var runtimeSync: RuntimeSyncStatus
  /// Legacy 快照发现与一次性完成标记。
  @Published private(set) var legacyImportState = LegacyImportAvailability(
    snapshotFound: false, completed: false)
  /// 最近一次 Legacy 导入报告（story 31）。
  @Published private(set) var legacyImportReport: LegacyImportReport?

  /// 组合根与测试装配的全部实现 adapter（issue #49）：coordinator、凭据、
  /// 插件、订阅获取、Legacy 导入服务、导入后回调与激活缝只经此束持有，
  /// 不再作为 workflow 属性暴露。仅供组合根与测试构造；视图不得访问——
  /// 独立 target 拆分前由 architecture deletion check 守护残余可见性。
  let dependencies: CatalogWorkflowDependencies
  /// 启动时发现的 Legacy 快照（导入编排用；秘密值不进 projection）。
  var discoveredLegacySnapshot: LegacySnapshot?

  /// 组合根注入依赖束；workflow 不自行创建任何生产 adapter（issue #49）。
  init(dependencies: CatalogWorkflowDependencies) {
    self.dependencies = dependencies
    let coordinator = dependencies.coordinator
    tree = .build(
      from: coordinator.committedCatalog,
      credentials: dependencies.credentials, plugins: dependencies.plugins)
    subscriptions = Self.subscriptionSummaries(
      coordinator.committedSubscriptions, catalog: coordinator.committedCatalog,
      credentials: dependencies.credentials)
    runtimeSync = coordinator.syncStatus
    coordinator.$syncStatus.assign(to: &$runtimeSync)
    refreshLegacyImportState()
  }

  // MARK: - 查询面

  /// 行显示名（导航标题、重命名预填等）；节点不存在为空串。
  func displayName(for id: NodeID) -> String {
    dependencies.coordinator.committedCatalog.entry(for: id)?.displayName ?? ""
  }

  /// 服务器叶子的已知阻塞原因（typed；编辑面「激活状态」区）。
  func serverInvalidReasons(for id: NodeID) -> [LeafInvalidationReason] {
    tree.node(withID: id)?.invalidReasons ?? []
  }

  /// 服务器编辑面（显式命令，story 11）：解析密码与受管插件参数明文。
  /// 节点不存在或不是服务器叶子为 `nil`。
  func serverEditForm(for id: NodeID) -> ServerEditForm? {
    guard let entry = dependencies.coordinator.committedCatalog.entry(for: id),
      case .server(let fields) = entry.kind
    else { return nil }
    let password = (try? dependencies.credentials.secret(for: fields.passwordRef)) ?? ""
    return ServerEditForm(
      address: fields.address,
      port: fields.port,
      encryptionMethod: fields.encryptionMethod,
      password: password,
      remark: fields.remark,
      plugin: pluginSectionState(for: fields),
      isEditable: entry.source == .manual)
  }

  /// 插件区状态（#38）：集内引用给可执行文件存在性事实与参数明文；集外引用
  /// 以显式 unknown 呈现（原样保留，激活语义由状态机点名拒绝）。
  private func pluginSectionState(for fields: ServerFields) -> PluginSectionState {
    let selection: PluginSelection
    if let program = fields.pluginProgram {
      selection =
        ManagedPluginCatalog.info(forProgram: program) != nil
        ? .managed(program: program)
        : .unknown(program: program)
    } else {
      selection = .none
    }
    var provided = false
    var options = ""
    if case .managed(let program) = selection {
      provided = dependencies.plugins.executablePath(forProgram: program) != nil
      options =
        fields.pluginOptionsRef.flatMap { (try? dependencies.credentials.secret(for: $0)) ?? "" }
        ?? ""
    }
    return PluginSectionState(
      selection: selection,
      managed: ManagedPluginCatalog.plugins,
      provided: provided,
      optionsPresent: fields.pluginOptionsRef != nil,
      options: options)
  }

  /// 添加落点：选中手动分组 → 组内；选中服务器 → 其父组（仅手动）；其余 → 根。
  func importTargetParent(for selection: NodeID?) -> NodeID? {
    let catalog = dependencies.coordinator.committedCatalog
    guard let selection, let entry = catalog.entry(for: selection) else { return nil }
    switch entry.kind {
    case .group:
      return entry.source == .manual ? selection : nil
    case .server:
      guard let parent = (try? catalog.parentID(of: selection)) ?? nil else { return nil }
      return catalog.entry(for: parent)?.source == .manual ? parent : nil
    }
  }

  // MARK: - 手动服务器/分组命令

  /// ss:// 批量导入（剪贴板、导入 URL、二维码识别三入口的共同落点，story 20/21）。
  /// 逐行解码，可解析行全部添加（每次新建身份，不按内容去重）；每条失败行以
  /// 行号 + 类型化原因点名，已成功记录不被局部失败回滚。
  func createServers(fromURIs text: String, into parent: NodeID?) async throws
    -> BatchImportOutcome
  {
    var prepared: [(uri: SsUri, fields: ServerFields)] = []
    var failures: [ImportLineFailure] = []
    for (index, line) in text.split(whereSeparator: \.isNewline).enumerated() {
      do {
        let uri = try SsUri.decode(String(line))
        let fields = try Self.serverFields(from: uri, credentials: dependencies.credentials)
        prepared.append((uri: uri, fields: fields))
      } catch {
        let reason: ImportLineFailureReason
        if let uriError = error as? SsUriError {
          reason = .decode(uriError)
        } else if let credentialError = error as? CredentialStoreError {
          reason = .credential(credentialError)
        } else {
          reason = .decode(.malformed(detail: String(describing: error)))
        }
        failures.append(ImportLineFailure(lineIndex: index, reason: reason))
      }
    }
    guard !prepared.isEmpty else { return BatchImportOutcome(addedCount: 0, failures: failures) }
    do {
      try commit { catalog in
        for item in prepared {
          try catalog.addServer(item.fields, to: parent)
        }
      }
    } catch {
      for item in prepared {
        Self.deleteCredentialRefs(for: item.fields, credentials: dependencies.credentials)
      }
      throw error
    }
    return BatchImportOutcome(addedCount: prepared.count, failures: failures)
  }

  /// 新建空手动分组（story 5）；返回新分组身份。
  @discardableResult
  func createGroup(named name: String, into parent: NodeID?) async throws -> NodeID {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw ServerFormError.emptyName }
    return try commit { catalog in
      try catalog.addGroup(trimmed, to: parent)
    }
  }

  /// 重命名手动分组：identity、父级与子项顺序不变（story 6）。
  func renameGroup(_ id: NodeID, to name: String) async throws {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw ServerFormError.emptyName }
    try commit { catalog in
      try catalog.renameGroup(id, to: trimmed)
    }
  }

  /// 拖拽/移动菜单落点（story 14/15）：跨来源、共享父级、成环由领域拒绝，
  /// typed error 原样上抛。
  func move(_ id: NodeID, to parent: NodeID?) async throws {
    try commit { catalog in
      try catalog.move(id, to: parent)
    }
  }

  /// 删除条目（手动分组递归删整棵子树，story 16/17）：尽力清理被删节点的
  /// Keychain 秘密；返回被删身份集合供 UI 清除失效选择（story 18）。
  func remove(_ id: NodeID) async throws -> RemovalOutcome {
    let removed: [CatalogEntry] = try commit { catalog in
      try catalog.remove(id)
    }
    for ref in Self.credentialRefs(of: removed) {
      try? dependencies.credentials.delete(ref)
    }
    return RemovalOutcome(removedNodeIDs: Set(removed.map(\.id)))
  }

  /// 服务器编辑提交（story 12/13）：配置与凭据作为一个逻辑变更；凭据写入经
  /// journal 记录原值，提交失败时全部恢复旧秘密，恢复结果经
  /// `CommitError.credentialRollback` 报出。插件选择按 #38 语义
  /// 落盘（「无」整体清除、受管写程序名与参数、集外引用原样保留）。
  func updateServer(_ id: NodeID, draft: ServerEditDraft) async throws {
    let trimmedAddress = draft.address.trimmingCharacters(in: .whitespaces)
    guard !trimmedAddress.isEmpty else { throw ServerFormError.invalidAddress }
    guard (1...65_535).contains(draft.port) else { throw ServerFormError.invalidPort }
    let trimmedMethod = draft.encryptionMethod.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedMethod.isEmpty else { throw ServerFormError.missingEncryptionMethod }
    guard EncryptionMethodCatalog.isSupported(trimmedMethod) else {
      throw ServerFormError.unsupportedEncryptionMethod(trimmedMethod)
    }
    guard !draft.password.isEmpty else { throw ServerFormError.invalidPassword }
    // 插件表单校验与其它字段同处写入之前：表单拒绝不触碰凭据、不进提交管线。
    if case .managed(let program) = draft.plugin,
      ManagedPluginCatalog.info(forProgram: program) == nil
    {
      throw ServerFormError.pluginNotManaged(program)
    }
    var journal = CredentialWriteJournal(credentials: dependencies.credentials)
    do {
      try commit { [self] catalog in
        guard let entry = catalog.entry(for: id), case .server(var fields) = entry.kind else {
          throw CatalogError.notAServer(id)
        }
        try journal.save(draft.password, for: fields.passwordRef)
        fields.address = trimmedAddress
        fields.port = draft.port
        fields.encryptionMethod = trimmedMethod
        fields.remark = draft.remark.trimmingCharacters(in: .whitespaces)
        try Self.applyPluginSelection(
          draft.plugin, options: draft.pluginOptions, to: &fields,
          credentials: dependencies.credentials, journal: &journal)
        try catalog.updateServer(id, with: fields)
      }
    } catch {
      throw CommitError(underlying: error, credentialRollback: journal.rollback())
    }
  }

  // MARK: - 提交管线（module 内部；UI 不得调用，独立 target 拆分前靠 deletion check）

  /// 仅目录变更的提交便捷入口（订阅扩展经 `commitSubscriptionDocument`）。
  private func commit<T>(
    _ mutate: (inout ConfigurationCatalog) throws -> T
  ) throws -> T {
    try commitDocument { catalog, _ in
      try mutate(&catalog)
    }
  }

  /// 副本变更 → 协调器落盘 → 重新发布 projection；任一步失败则已发布状态
  /// 不动。运行时收敛由协调器异步调度（issue #40），不阻塞也不回滚本提交。
  private func commitDocument<T>(
    _ mutate: (inout ConfigurationCatalog, inout [SubscriptionRecord]) throws -> T
  ) throws -> T {
    let result = try dependencies.coordinator.commit(mutate)
    republishCommittedState()
    return result
  }

  /// 订阅扩展的唯一写路径（module 内部窄缝，替代直接摸 `commitDocument`）。
  func commitSubscriptionDocument<T>(
    _ mutate: (inout ConfigurationCatalog, inout [SubscriptionRecord]) throws -> T
  ) throws -> T {
    try commitDocument(mutate)
  }

  /// 提交成功后的 projection 重建（树 + 订阅卡片）。
  func republishCommittedState() {
    let coordinator = dependencies.coordinator
    tree = .build(
      from: coordinator.committedCatalog,
      credentials: dependencies.credentials, plugins: dependencies.plugins)
    subscriptions = Self.subscriptionSummaries(
      coordinator.committedSubscriptions, catalog: coordinator.committedCatalog,
      credentials: dependencies.credentials)
  }

  // MARK: - module 内部发布缝（扩展文件经此更新只读投影，setter 保持 private）

  func publishLegacyImportState(_ state: LegacyImportAvailability) {
    legacyImportState = state
  }

  func publishLegacyImportReport(_ report: LegacyImportReport?) {
    legacyImportReport = report
  }

  /// 订阅刷新并发守卫的写入口（集合对外只读）。
  func setRefreshInFlight(_ id: NodeID, _ inFlight: Bool) {
    if inFlight {
      refreshingSubscriptionIDs.insert(id)
    } else {
      refreshingSubscriptionIDs.remove(id)
    }
  }

  func setSubscriptionRefreshFailure(
    _ result: SubscriptionRefreshFailureResult?, for id: NodeID
  ) {
    if let result {
      subscriptionRefreshFailures[id] = result
    } else {
      subscriptionRefreshFailures.removeValue(forKey: id)
    }
  }
}
