/// 配置目录：不可见的配置树根（CONTEXT.md「Configuration catalog」）。有序顶层
/// 子节点为服务器配置或配置组。存储形态：全量节点表 + 根序 + 各分组显子序；
/// 单父由「一个身份只出现在一条子序里」构造保证，无环与来源分离由操作校验。
///
/// 插入位置的统一语义：`index` 以摘除移动节点后的目标子序为准（重排同父节点时
/// 即「先取出再插入」的直觉顺序），`nil` 表示追加到末尾；失败的操作不产生任何变更。
struct ConfigurationCatalog: Equatable, Sendable {
  private(set) var rootChildren: [NodeID] = []
  private(set) var entries: [NodeID: CatalogEntry] = [:]

  init() {}

  /// 从持久化载荷重建目录（private；外部入口走 `validated(rootChildren:entries:)`）。
  private init(rootChildren: [NodeID], entries: [NodeID: CatalogEntry]) {
    self.rootChildren = rootChildren
    self.entries = entries
  }

  /// 外部载荷（持久化文件）的唯一重建入口：结构不一致（悬空子引用、共享父、
  /// 成环、不可达节点）即抛 `invalidStructure`。从根出发的一次遍历同时覆盖
  /// 全部四类检查——重复到达即共享父或成环，未到达即不可达或根外孤环。
  static func validated(
    rootChildren: [NodeID],
    entries: [NodeID: CatalogEntry]
  ) throws -> ConfigurationCatalog {
    var visited = Set<NodeID>()
    var pending = rootChildren
    while let current = pending.popLast() {
      guard visited.insert(current).inserted else {
        throw CatalogError.invalidStructure(
          "node \(current.rawValue) reached twice (shared parent or cycle)")
      }
      guard let entry = entries[current] else {
        throw CatalogError.invalidStructure("dangling child \(current.rawValue)")
      }
      if case .group(let fields) = entry.kind { pending.append(contentsOf: fields.children) }
    }
    guard visited.count == entries.count else {
      throw CatalogError.invalidStructure("unreachable or disconnected-cycle nodes present")
    }
    return ConfigurationCatalog(rootChildren: rootChildren, entries: entries)
  }
}

// MARK: - 查询

extension ConfigurationCatalog {
  var isEmpty: Bool { entries.isEmpty }

  func contains(_ id: NodeID) -> Bool { entries[id] != nil }

  func entry(for id: NodeID) -> CatalogEntry? { entries[id] }

  /// 子节点序；`nil` 表示目录根。
  func children(of parent: NodeID?) throws -> [NodeID] {
    guard let parent else { return rootChildren }
    guard let entry = entries[parent] else { throw CatalogError.parentNotFound(parent) }
    guard case .group(let fields) = entry.kind else { throw CatalogError.parentNotAGroup(parent) }
    return fields.children
  }

  /// 直接父节点；根层节点返回 `nil`。节点必须存在，否则抛错。
  func parentID(of id: NodeID) throws -> NodeID? {
    guard entries[id] != nil else { throw CatalogError.nodeNotFound(id) }
    return parentIndex()[id]
  }

  /// 从父到根的祖先链（不含自身）。根层节点返回空。
  func ancestors(of id: NodeID) -> [NodeID] {
    let parents = parentIndex()
    var chain: [NodeID] = []
    var current = parents[id]
    while let parent = current {
      chain.append(parent)
      current = parents[parent]
    }
    return chain
  }

  /// 全量父索引（根层节点不在其中）。
  func parentIndex() -> [NodeID: NodeID] {
    var parents: [NodeID: NodeID] = [:]
    for entry in entries.values {
      guard case .group(let fields) = entry.kind else { continue }
      for child in fields.children { parents[child] = entry.id }
    }
    return parents
  }

}

// MARK: - 变更

extension ConfigurationCatalog {
  @discardableResult
  mutating func addServer(
    _ fields: ServerFields,
    source: NodeSource = .manual,
    id proposedID: NodeID? = nil,
    to parent: NodeID? = nil,
    index: Int? = nil
  ) throws -> NodeID {
    let id = proposedID ?? .fresh()
    guard entries[id] == nil else { throw CatalogError.duplicateID(id) }
    if source == .subscription && parent == nil {
      throw CatalogError.subscriptionServerAtRoot(id)
    }
    try place(id, source: source, parent: parent, index: index, excluding: nil)
    entries[id] = CatalogEntry(id: id, source: source, kind: .server(fields))
    return id
  }

  @discardableResult
  mutating func addGroup(
    _ name: String,
    source: NodeSource = .manual,
    id proposedID: NodeID? = nil,
    to parent: NodeID? = nil,
    index: Int? = nil
  ) throws -> NodeID {
    let id = proposedID ?? .fresh()
    guard entries[id] == nil else { throw CatalogError.duplicateID(id) }
    try place(id, source: source, parent: parent, index: index, excluding: nil)
    entries[id] = CatalogEntry(id: id, source: source, kind: .group(GroupFields(name: name)))
    return id
  }

  mutating func renameGroup(_ id: NodeID, to name: String) throws {
    guard var entry = entries[id] else { throw CatalogError.nodeNotFound(id) }
    guard entry.source == .manual else { throw CatalogError.subscriptionNodeImmutable(id) }
    guard case .group(var fields) = entry.kind else { throw CatalogError.notAGroup(id) }
    fields.name = name
    entry.kind = .group(fields)
    entries[id] = entry
  }

  mutating func updateServer(_ id: NodeID, with fields: ServerFields) throws {
    guard var entry = entries[id] else { throw CatalogError.nodeNotFound(id) }
    guard entry.source == .manual else { throw CatalogError.subscriptionNodeImmutable(id) }
    guard case .server = entry.kind else { throw CatalogError.notAServer(id) }
    entry.kind = .server(fields)
    entries[id] = entry
  }

  /// 移动节点（携带整棵子树）：目录根与手动组之间、手动组相互之间。
  /// 同父移动即重排。跨来源、共享父、成环一律拒绝。
  mutating func move(_ id: NodeID, to parent: NodeID?, index: Int? = nil) throws {
    guard let entry = entries[id] else { throw CatalogError.nodeNotFound(id) }
    guard entry.source == .manual else { throw CatalogError.subscriptionNodeImmutable(id) }
    if let parent, parent == id || ancestors(of: parent).contains(id) {
      throw CatalogError.cycleDetected(id)
    }
    try place(id, source: entry.source, parent: parent, index: index, excluding: id)
  }

  /// 删除节点；手动分组递归删除整棵子树。返回被删除的节点（含其凭据引用，
  /// 供调用方清理 Keychain 秘密）。空组允许显式删除；空组本身持久保留。
  @discardableResult
  mutating func remove(_ id: NodeID) throws -> [CatalogEntry] {
    guard let root = entries[id] else { throw CatalogError.nodeNotFound(id) }
    guard root.source == .manual else { throw CatalogError.subscriptionNodeImmutable(id) }

    var removed: [CatalogEntry] = []
    var pending = [id]
    while let current = pending.popLast() {
      guard let entry = entries[current] else { continue }
      if case .group(let fields) = entry.kind { pending.append(contentsOf: fields.children) }
      removed.append(entry)
      entries[current] = nil
    }
    removeFromSiblings(id)
    return removed
  }

  /// 校验目标容器（存在、是分组、来源一致）与插入位置，返回放入 id 后的完整子序。
  /// 全部校验先于任何变更，失败抛错时状态不动。`excluding` 为移动语义下先摘除的节点自身。
  private mutating func place(
    _ id: NodeID,
    source: NodeSource,
    parent: NodeID?,
    index: Int?,
    excluding excludeID: NodeID?
  ) throws {
    let siblings: [NodeID]
    if let parent {
      guard let container = entries[parent] else { throw CatalogError.parentNotFound(parent) }
      guard case .group(let fields) = container.kind else {
        throw CatalogError.parentNotAGroup(parent)
      }
      guard container.source == source else {
        throw CatalogError.crossSourcePlacement(node: source, container: container.source)
      }
      siblings = fields.children
    } else {
      siblings = rootChildren
    }
    var children = siblings
    if let excludeID { children.removeAll { $0 == excludeID } }
    let position = index ?? children.count
    guard (0...children.count).contains(position) else {
      throw CatalogError.indexOutOfRange(parent: parent, index: index, childCount: children.count)
    }
    children.insert(id, at: position)

    removeFromSiblings(id)
    if let parent {
      setChildren(children, of: parent)
    } else {
      rootChildren = children
    }
  }

  /// 把节点从其现所在子序（父分组或根）摘除；根层节点静默摘除。
  private mutating func removeFromSiblings(_ id: NodeID) {
    if let oldParent = parentIndex()[id] {
      guard case .group(let fields) = entries[oldParent]?.kind else {
        preconditionFailure("父索引与节点表不一致")
      }
      setChildren(fields.children.filter { $0 != id }, of: oldParent)
    } else {
      rootChildren.removeAll { $0 == id }
    }
  }

  private mutating func setChildren(_ children: [NodeID], of parent: NodeID) {
    precondition(entries[parent] != nil, "父容器已先行校验存在")
    guard case .group(var fields) = entries[parent]?.kind else {
      preconditionFailure("父容器已先行校验为分组")
    }
    fields.children = children
    entries[parent]?.kind = .group(fields)
  }
}

// MARK: - 订阅子树（spec #21 D4，issue #35：快照原子提交与递归清除）

extension ConfigurationCatalog {
  /// 订阅固定分组子树的全量条目（含固定分组自身）；不存在或不是分组即抛错。
  func subscriptionSubtree(of groupID: NodeID) throws -> [CatalogEntry] {
    guard let entry = entries[groupID], case .group = entry.kind else {
      throw CatalogError.notAGroup(groupID)
    }
    var collected: [CatalogEntry] = []
    var pending = [groupID]
    while let current = pending.popLast() {
      guard let currentEntry = entries[current] else { continue }
      if case .group(let fields) = currentEntry.kind {
        pending.append(contentsOf: fields.children)
      }
      collected.append(currentEntry)
    }
    return collected
  }

  /// 订阅快照原子应用（CONTEXT.md 刷新契约）：以快照整体重建固定分组子树；
  /// 名称、结构、顺序和连接字段全部跟随远端（扩展缺失时由调用方给 URL host
  /// 兜底）。返回被移除的旧服务器叶子（供调用方清理凭据）。
  @discardableResult
  mutating func applySubscriptionSnapshot(
    _ snapshot: CatalogSubscriptionSnapshot, into groupID: NodeID
  ) throws -> [CatalogEntry] {
    guard let fixed = entries[groupID], case .group = fixed.kind else {
      throw CatalogError.notAGroup(groupID)
    }
    guard fixed.source == .subscription else {
      throw CatalogError.crossSourcePlacement(node: .subscription, container: fixed.source)
    }

    // 先整树摘除旧成员（固定分组本身保留），收集被移除的服务器。
    var removedServers: [CatalogEntry] = []
    let oldSubtree = try subscriptionSubtree(of: groupID)
    for entry in oldSubtree {
      if case .server = entry.kind { removedServers.append(entry) }
    }
    for entry in oldSubtree where entry.id != groupID {
      entries[entry.id] = nil
    }
    setChildren([], of: groupID)

    // 远端权威重建：名称、结构、顺序、字段全按快照。
    var fixedFields = GroupFields(name: snapshot.name, children: [])
    try insertSnapshotChildren(of: snapshot.root, into: &fixedFields)
    entries[groupID]?.kind = .group(fixedFields)
    return removedServers
  }

  /// 递归挂载快照分组：嵌套分组与服务器叶子以快照身份按序重建，并产出父
  /// 分组的显子序。身份已由解析器按订阅作用域限定，与既有节点冲突即程序错误。
  private mutating func insertSnapshotChildren(
    of group: CatalogSubscriptionSnapshot.Group,
    into fields: inout GroupFields
  ) throws {
    var childIDs: [NodeID] = []
    for child in group.children {
      switch child {
      case .server(let leaf):
        guard entries[leaf.id] == nil else { throw CatalogError.duplicateID(leaf.id) }
        entries[leaf.id] = CatalogEntry(
          id: leaf.id, source: .subscription, kind: .server(leaf.fields))
        childIDs.append(leaf.id)
      case .group(let nested):
        guard entries[nested.id] == nil else { throw CatalogError.duplicateID(nested.id) }
        var nestedFields = GroupFields(name: nested.name, children: [])
        try insertSnapshotChildren(of: nested, into: &nestedFields)
        entries[nested.id] = CatalogEntry(
          id: nested.id, source: .subscription, kind: .group(nestedFields))
        childIDs.append(nested.id)
      }
    }
    fields.children = childIDs
  }

  /// 删除订阅：固定分组整棵子树连同固定分组本身一并移除（递归清除，不留
  /// 墓碑）。返回被删条目（含凭据引用，供调用方清理 Keychain 秘密）。
  @discardableResult
  mutating func removeSubscriptionSubtree(of groupID: NodeID) throws -> [CatalogEntry] {
    let subtree = try subscriptionSubtree(of: groupID)
    for entry in subtree {
      entries[entry.id] = nil
    }
    removeFromSiblings(groupID)
    return subtree
  }
}
