import Foundation
import SwiftUI

/// 主窗口视图模型（issue #32/#35）：把 ConfigurationCatalog 领域语义接到树
/// 操作、详情表单、添加三入口、分享与订阅生命周期。所有变更走「副本变更 →
/// 落盘 → 发布 → postCommit 重展开」，失败即整体不变更；凭据读写只在模型层
/// 出现。
@MainActor
final class CatalogViewModel: ObservableObject {
  @Published private(set) var catalog: ConfigurationCatalog
  @Published private(set) var subscriptions: [SubscriptionRecord] = []
  /// 正在刷新的订阅（并发守卫：同一订阅不重入，issue #35）。
  @Published private(set) var inFlightRefreshIDs: Set<NodeID> = []
  @Published var selectedNodeID: NodeID?
  /// 需要弹窗呈现的错误（领域拒绝、导入失败、凭据失败）。
  @Published var presentedError: String?

  private let fileStore: CatalogFileStore
  /// 订阅扩展（CatalogViewModel+Subscriptions）同样经此读写凭据。
  let credentials: CredentialStoring
  private let plugins: ManagedPluginProviding
  /// 订阅获取缝（默认 URLSession 实现；测试注入夹具，issue #35）。
  var subscriptionFetcher: SubscriptionFetching
  /// 目录提交后的运行时重展开（生产接线 `ProxyRuntimeController.catalogDidCommit`）。
  var postCommit: (() async -> Void)?

  init(
    fileStore: CatalogFileStore = CatalogFileStore(fileURL: CatalogFileStore.defaultFileURL()),
    credentials: CredentialStoring = KeychainCredentialStore(),
    plugins: ManagedPluginProviding = NoManagedPluginProvider(),
    subscriptionFetcher: SubscriptionFetching = HTTPSSubscriptionFetcher()
  ) {
    self.fileStore = fileStore
    self.credentials = credentials
    self.plugins = plugins
    self.subscriptionFetcher = subscriptionFetcher
    let loaded = (try? fileStore.load()) ?? CatalogDocument()
    catalog = loaded.catalog
    subscriptions = loaded.subscriptions
  }

  // MARK: - 查询面

  /// 订阅刷新并发守卫的写入口（扩展文件使用；保持集合只对外可读）。
  func setSubscriptionRefreshInFlight(_ id: NodeID, _ inFlight: Bool) {
    if inFlight {
      inFlightRefreshIDs.insert(id)
    } else {
      inFlightRefreshIDs.remove(id)
    }
  }

  func entry(for id: NodeID) -> CatalogEntry? { catalog.entry(for: id) }

  func parentID(of id: NodeID) -> NodeID? { (try? catalog.parentID(of: id)) ?? nil }

  func isEffectivelyEnabled(_ id: NodeID) -> Bool {
    (try? catalog.isEffectivelyEnabled(id)) ?? false
  }

  /// 行显示名：委托目录条目的共用口径（`CatalogEntry.displayName`）。
  func displayName(for id: NodeID) -> String {
    catalog.entry(for: id)?.displayName ?? ""
  }

  // MARK: - 侧栏树快照

  func sidebarNodes() -> [SidebarNode] {
    sidebarChildren(of: nil)
  }

  private func sidebarChildren(of parent: NodeID?) -> [SidebarNode] {
    let ids = (try? catalog.children(of: parent)) ?? []
    return ids.compactMap { id in
      guard let entry = catalog.entry(for: id) else { return nil }
      let isGroup: Bool = {
        if case .group = entry.kind { return true }
        return false
      }()
      return SidebarNode(
        id: id,
        name: displayName(for: id),
        isGroup: isGroup,
        source: entry.source,
        enabled: entry.enabled,
        effectivelyEnabled: isEffectivelyEnabled(id),
        children: isGroup ? sidebarChildren(of: id) : nil)
    }
  }

  // MARK: - 变更面（CatalogError / ServerFormError / CredentialStoreError 上抛）

  /// ss:// 批量导入（剪贴板、导入 URL、二维码识别三入口的共同落点）。
  /// 逐行解码，可解析行全部添加（每次新建身份，不按内容去重）；返回成功条数
  /// 与失败行的点名原因。
  func addServers(fromURIs text: String, into parent: NodeID?) async throws -> (
    added: Int, failures: [String]
  ) {
    var parsed: [SsUri] = []
    var failures: [String] = []
    for line in text.split(whereSeparator: \.isNewline) {
      do {
        parsed.append(try SsUri.decode(String(line)))
      } catch {
        let digest = line.count > 24 ? "\(line.prefix(24))…" : line
        let reason = (error as? SsUriError).map { String(describing: $0) } ?? "未知错误"
        failures.append("「\(digest)」：\(reason)")
      }
    }
    try await commit { catalog in
      for uri in parsed {
        let fields = try Self.serverFields(from: uri, credentials: credentials)
        try catalog.addServer(fields, to: parent)
      }
    }
    return (parsed.count, failures)
  }

  @discardableResult
  func addGroup(named name: String, into parent: NodeID?) async throws -> NodeID {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw ServerFormError.emptyName }
    return try await commit { catalog in
      try catalog.addGroup(trimmed, to: parent)
    }
  }

  func renameGroup(_ id: NodeID, to name: String) async throws {
    let trimmed = name.trimmingCharacters(in: .whitespaces)
    guard !trimmed.isEmpty else { throw ServerFormError.emptyName }
    try await commit { catalog in
      try catalog.renameGroup(id, to: trimmed)
    }
  }

  func setEnabled(_ id: NodeID, _ enabled: Bool) async throws {
    try await commit { catalog in
      try catalog.setEnabled(id, enabled)
    }
  }

  /// 拖拽/移动菜单落点。跨来源、成环、移动进自身由领域拒绝，原样上抛呈现。
  func move(_ id: NodeID, to parent: NodeID?) async throws {
    try await commit { catalog in
      try catalog.move(id, to: parent)
    }
  }

  /// 删除（手动分组递归删整棵子树），并尽力清理被删节点的 Keychain 秘密。
  func remove(_ id: NodeID) async throws {
    let removed: [CatalogEntry] = try await commit { catalog in
      try catalog.remove(id)
    }
    if let selection = selectedNodeID, removed.contains(where: { $0.id == selection }) {
      selectedNodeID = nil
    }
    for entry in removed {
      if let fields = serverFields(of: entry) {
        try? credentials.delete(fields.passwordRef)
        if let optionsRef = fields.pluginOptionsRef { try? credentials.delete(optionsRef) }
      }
    }
  }

  /// 详情表单提交（手动服务器）。密码经凭据存储覆盖写；插件区本票只读不在此改。
  func updateServer(
    _ id: NodeID,
    address: String,
    port: Int,
    encryptionMethod: String,
    password: String,
    remark: String
  ) async throws {
    let trimmedAddress = address.trimmingCharacters(in: .whitespaces)
    guard !trimmedAddress.isEmpty else { throw ServerFormError.invalidAddress }
    guard (1...65_535).contains(port) else { throw ServerFormError.invalidPort }
    try await commit { catalog in
      guard let entry = catalog.entry(for: id), case .server(var fields) = entry.kind else {
        throw CatalogError.notAServer(id)
      }
      try credentials.save(password, for: fields.passwordRef)
      fields.address = trimmedAddress
      fields.port = port
      fields.encryptionMethod = encryptionMethod
      fields.remark = remark.trimmingCharacters(in: .whitespaces)
      try catalog.updateServer(id, with: fields)
    }
  }

  // MARK: - 详情表单

  func serverFormState(for id: NodeID) -> ServerFormState? {
    guard let entry = catalog.entry(for: id), case .server(let fields) = entry.kind else {
      return nil
    }
    let password = (try? credentials.secret(for: fields.passwordRef)) ?? ""
    let plugin = fields.pluginProgram.map { program in
      PluginDisplay(
        program: program,
        provided: plugins.executablePath(forProgram: program) != nil,
        optionsPresent: fields.pluginOptionsRef != nil)
    }
    return ServerFormState(
      address: fields.address,
      port: fields.port,
      encryptionMethod: fields.encryptionMethod,
      password: password,
      remark: fields.remark,
      plugin: plugin,
      isEditable: entry.source == .manual)
  }

  func isPluginProvided(_ program: String) -> Bool {
    plugins.executablePath(forProgram: program) != nil
  }

  // MARK: - 分享

  /// 服务器 → ss://（SIP002）：凭据从存储解析；无凭据即点名失败（不分享空档）。
  func ssUri(for id: NodeID) throws -> String {
    guard let entry = catalog.entry(for: id), case .server(let fields) = entry.kind else {
      throw CatalogError.notAServer(id)
    }
    guard let password = try credentials.secret(for: fields.passwordRef) else {
      throw CredentialStoreError.keychainStatus(errSecItemNotFound)
    }
    var pluginOptions: String?
    if let optionsRef = fields.pluginOptionsRef {
      pluginOptions = try credentials.secret(for: optionsRef) ?? ""
    }
    return SsUri(
      method: fields.encryptionMethod,
      password: password,
      host: fields.address,
      port: fields.port,
      pluginProgram: fields.pluginProgram,
      pluginOptions: pluginOptions,
      remark: fields.remark.isEmpty ? nil : fields.remark
    ).encode()
  }

  /// 添加落点：选中手动分组 → 组内；选中服务器 → 其父组（仅手动）；其余 → 根。
  func importTargetParent(for selection: NodeID?) -> NodeID? {
    guard let selection, let entry = catalog.entry(for: selection) else { return nil }
    switch entry.kind {
    case .group:
      return entry.source == .manual ? selection : nil
    case .server:
      guard let parent = parentID(of: selection) else { return nil }
      return catalog.entry(for: parent)?.source == .manual ? parent : nil
    }
  }

  // MARK: - 提交管线

  /// 副本变更 → 落盘 → 发布 → postCommit；任一步失败则已发布状态不动。
  private func commit<T>(
    _ mutate: (inout ConfigurationCatalog) throws -> T
  ) async throws -> T {
    try await commitDocument { catalog, _ in
      try mutate(&catalog)
    }
  }

  /// 目录 + 订阅记录同文档提交（订阅刷新/创建/删除共用）：任一步失败则已
  /// 发布状态不动，成功才依次发布并触发运行时重展开。
  func commitDocument<T>(
    _ mutate: (inout ConfigurationCatalog, inout [SubscriptionRecord]) throws -> T
  ) async throws -> T {
    var workingCatalog = catalog
    var workingSubscriptions = subscriptions
    let result = try mutate(&workingCatalog, &workingSubscriptions)
    try fileStore.save(
      CatalogDocument(catalog: workingCatalog, subscriptions: workingSubscriptions))
    catalog = workingCatalog
    subscriptions = workingSubscriptions
    await postCommit?()
    return result
  }

  /// URI → 服务器叶子字段：密码与插件参数入凭据存储、目录只持引用。
  private static func serverFields(
    from uri: SsUri, credentials: CredentialStoring
  ) throws -> ServerFields {
    let passwordRef = CredentialReference.fresh()
    try credentials.save(uri.password, for: passwordRef)
    var pluginProgram: String?
    var pluginOptionsRef: CredentialReference?
    if let program = uri.pluginProgram {
      pluginProgram = program
      if let options = uri.pluginOptions {
        let ref = CredentialReference.fresh()
        try credentials.save(options, for: ref)
        pluginOptionsRef = ref
      }
    }
    return ServerFields(
      address: uri.host,
      port: uri.port,
      encryptionMethod: uri.method,
      passwordRef: passwordRef,
      remark: uri.remark ?? "",
      pluginProgram: pluginProgram,
      pluginOptionsRef: pluginOptionsRef)
  }

  private func serverFields(of entry: CatalogEntry) -> ServerFields? {
    if case .server(let fields) = entry.kind { return fields }
    return nil
  }
}

/// 表单级校验失败（地址/端口/名称）；领域拒绝仍以 CatalogError 上抛。
enum ServerFormError: Error, Equatable {
  case invalidAddress
  case invalidPort
  case emptyName
}
