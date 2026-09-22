import Foundation

// MARK: - 目录树 projection（非敏感）

/// 目录树节点快照（目录工作流 module 的 UI-facing projection，issue #41）：
/// 名称、来源、形态、校验事实与子树计数；不含凭据引用、密码、插件参数等
/// 秘密值。身份为不透明 `NodeID`，重命名、移动或刷新后保持稳定（story 3）。
struct CatalogTreeNode: Identifiable, Equatable {
  let id: NodeID
  let name: String
  let isGroup: Bool
  let source: NodeSource
  /// 父节点身份；目录根层节点为 `nil`。
  let parentID: NodeID?
  /// 服务器叶子的 app 可知校验结果；分组为 `nil`。
  let validation: ServerValidation?
  /// 直接子节点数（分组）。
  let childCount: Int
  /// 子树全部后代节点数（分组；不含自身；删除确认的递归规模）。
  let subtreeNodeCount: Int
  /// 子树中已知无效的服务器数量（不含当前叶子自身）。
  let invalidDescendantCount: Int
  /// 子树中服务器叶子总数（叶子为 1）。
  let serverCount: Int
  /// 分组持有子树快照；服务器叶子为 `nil`。
  let children: [CatalogTreeNode]?

  var isInvalid: Bool { validation?.isValid == false }
  var invalidServerCount: Int { (isInvalid ? 1 : 0) + invalidDescendantCount }
  var isManual: Bool { source == .manual }
  /// 子树快照；服务器叶子为空（与 `children` 的 nil 区分叶子语义并存）。
  var childNodes: [CatalogTreeNode] { children ?? [] }
}

extension CatalogTreeNode {
  /// 深度优先查找子树中的节点（含自身）。
  func find(_ id: NodeID) -> CatalogTreeNode? {
    if id == self.id { return self }
    for child in children ?? [] {
      if let found = child.find(id) { return found }
    }
    return nil
  }

  /// 子树全部节点身份（含自身）。
  var subtreeIDs: Set<NodeID> {
    var ids: Set<NodeID> = [id]
    for child in children ?? [] { ids.formUnion(child.subtreeIDs) }
    return ids
  }
}

/// 目录树快照：侧栏、活动目标级联、移动目的地与删除确认共用的同一份
/// 非敏感 projection；UI 不再持有原始目录副本（issue #41）。
struct CatalogTreeSnapshot: Equatable {
  let roots: [CatalogTreeNode]

  var isEmpty: Bool { roots.isEmpty }

  /// 深度优先查找节点（含子树）。
  func node(withID id: NodeID) -> CatalogTreeNode? {
    for node in roots {
      if let found = node.find(id) { return found }
    }
    return nil
  }

  /// 节点是否在树中（拖拽负载存在性校验）。
  func containsNode(_ id: NodeID) -> Bool { node(withID: id) != nil }

  /// 全树已知无效服务器总数（诊断计数）。
  var invalidServerCount: Int { roots.reduce(0) { $0 + $1.invalidServerCount } }
}

extension CatalogTreeSnapshot {
  /// 从已提交目录构建 projection（module 内部推导；测试同 target 可直接调用）。
  /// 每个服务器叶子求值一次激活校验（与既有口径一致，读凭据存储）。
  static func build(
    from catalog: ConfigurationCatalog,
    credentials: CredentialStoring,
    plugins: ManagedPluginProviding
  ) -> CatalogTreeSnapshot {
    func buildNode(_ id: NodeID, entry: CatalogEntry, parentID: NodeID?) -> CatalogTreeNode {
      switch entry.kind {
      case .group(let fields):
        let children = fields.children.compactMap { childID -> CatalogTreeNode? in
          guard let childEntry = catalog.entry(for: childID) else { return nil }
          return buildNode(childID, entry: childEntry, parentID: id)
        }
        return CatalogTreeNode(
          id: id,
          name: entry.displayName,
          isGroup: true,
          source: entry.source,
          parentID: parentID,
          validation: nil,
          childCount: children.count,
          subtreeNodeCount: children.reduce(0) { $0 + 1 + $1.subtreeNodeCount },
          invalidDescendantCount: children.reduce(0) { $0 + $1.invalidServerCount },
          serverCount: children.reduce(0) { $0 + $1.serverCount },
          children: children)
      case .server(let fields):
        return CatalogTreeNode(
          id: id,
          name: entry.displayName,
          isGroup: false,
          source: entry.source,
          parentID: parentID,
          validation: ServerValidation.evaluate(fields, credentials: credentials, plugins: plugins),
          childCount: 0,
          subtreeNodeCount: 0,
          invalidDescendantCount: 0,
          serverCount: 1,
          children: nil)
      }
    }
    let roots = catalog.rootChildren.compactMap { id -> CatalogTreeNode? in
      guard let entry = catalog.entry(for: id) else { return nil }
      return buildNode(id, entry: entry, parentID: nil)
    }
    return CatalogTreeSnapshot(roots: roots)
  }
}

// MARK: - 服务器详情与编辑

/// 服务器编辑面状态：用户打开编辑器时经显式命令解析，凭据明文只在此出现
/// （story 10/11）；不属于普通 projection。
struct ServerEditForm: Equatable {
  let address: String
  let port: Int
  let encryptionMethod: String
  let password: String
  let remark: String
  let plugin: PluginSectionState
  let isEditable: Bool
}

/// 服务器编辑的提交载荷（typed command）：配置与凭据字段作为一个逻辑变更
/// 提交（story 12）；任一持久化步骤失败时旧配置与旧凭据继续生效（story 13）。
struct ServerEditDraft: Equatable {
  var address: String
  var port: Int
  var encryptionMethod: String
  var password: String
  var remark: String
  var plugin: PluginSelection
  var pluginOptions: String?
}

/// 插件选择器选中态（D10）：「无」、受管集内程序、受管集外引用。集外引用
/// （Legacy 导入或订阅带入）以显式「本版本未提供」状态呈现并原样保留。
/// Hashable 以直接充当 SwiftUI Picker 的选中值。
enum PluginSelection: Hashable {
  case none
  case managed(program: String)
  case unknown(program: String)
}

/// 插件区表单状态：选中态、受管事实表、提供事实与参数明文（编辑面）。
struct PluginSectionState: Equatable {
  let selection: PluginSelection
  /// 本版本受管集（「无」不由这里提供）。
  let managed: [ManagedPluginInfo]
  /// 当前受管引用的可执行文件是否在位（生成配置时的存在性检查事实）。
  let provided: Bool
  /// 参数是否已配置（存于钥匙串）。
  let optionsPresent: Bool
  /// 参数明文（仅受管选中态解析，供参数输入框预填；其余为空串）。
  let options: String
}

// MARK: - 订阅 projection

/// 订阅卡片 projection（非敏感）：完整 URL 不出现，只含 host（story 23）；
/// 状态为结构化值，本地化文案与日期格式由 UI 呈现层派生（story 42）。
struct SubscriptionSummary: Identifiable, Equatable {
  let id: NodeID
  let groupID: NodeID
  let name: String
  let host: String
  let status: SubscriptionRefreshStatus
  let serverCount: Int
}

// MARK: - 命令结果（structured outcome）

/// 批量导入的逐行结构化结果（story 20/21）：成功计数 + 失败行点名（行号 +
/// 类型化原因）；部分失败不回滚已成功记录。原始行文本由 UI 自行持有，摘要
/// 在呈现层截取，秘密值不出 module。
struct BatchImportOutcome: Equatable {
  let addedCount: Int
  let failures: [ImportLineFailure]
}

struct ImportLineFailure: Equatable {
  /// 失败行在输入文本按换行切分后的下标（0 起）。
  let lineIndex: Int
  let reason: ImportLineFailureReason
}

enum ImportLineFailureReason: Equatable, Error {
  case decode(SsUriError)
  case credential(CredentialStoreError)
}

/// 删除结果：被删节点身份集合。UI 据此清除失效选择（selection invalidation，
/// story 18）；不自动改选相邻节点，活动目标语义不受影响。
struct RemovalOutcome: Equatable, Sendable {
  let removedNodeIDs: Set<NodeID>
}

// MARK: - Legacy 导入可用性

/// Legacy 快照发现与完成标记（story 31/34）：跳过不写标记，显式再导入仍
/// 创建新的独立手动分组。
struct LegacyImportAvailability: Equatable {
  let snapshotFound: Bool
  let completed: Bool

  var shouldOffer: Bool { snapshotFound && !completed }
}

// MARK: - 表单级 typed error（本地化由 UI 呈现层负责）

/// 表单级校验失败（地址/端口/名称）；领域拒绝仍以 `CatalogError` 上抛。
enum ServerFormError: Error, Equatable {
  case invalidAddress
  case invalidPort
  case missingEncryptionMethod
  case unsupportedEncryptionMethod(String)
  case invalidPassword
  case emptyName
  /// 提交了受管集之外的插件选择（表单只能产生受管集内的选择，此为程序错误防线的显式拒绝）。
  case pluginNotManaged(String)
}

/// 订阅表单级失败（URL 门禁、订阅不存在）；获取/解析失败仍以原错误上抛。
enum SubscriptionFormError: Error, Equatable {
  case invalidURL
  case notFound
}
