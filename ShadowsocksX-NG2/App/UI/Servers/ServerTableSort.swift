import Foundation

/// 展示排序不改写目录顺序；未知时间在两个方向都排在最后。
struct ServerTableSort: SortComparator {
  enum Field: CaseIterable {
    case name, createdAt, updatedAt
  }

  let field: Field
  var order: SortOrder

  init(_ field: Field, order: SortOrder = .forward) {
    self.field = field
    self.order = order
  }

  func compare(_ lhs: CatalogTreeNode, _ rhs: CatalogTreeNode) -> ComparisonResult {
    let result: ComparisonResult
    switch field {
    case .name:
      result = lhs.name.localizedStandardCompare(rhs.name)
    case .createdAt, .updatedAt:
      let left = field == .createdAt ? lhs.createdAt : lhs.updatedAt
      let right = field == .createdAt ? rhs.createdAt : rhs.updatedAt
      switch (left, right) {
      case (nil, nil): return .orderedSame
      case (nil, _): return .orderedDescending
      case (_, nil): return .orderedAscending
      case (.some(let left), .some(let right)): result = left.compare(right)
      }
    }
    guard order == .reverse else { return result }
    switch result {
    case .orderedAscending: return .orderedDescending
    case .orderedDescending: return .orderedAscending
    case .orderedSame: return .orderedSame
    }
  }

  static func sorted(_ nodes: [CatalogTreeNode], by sortOrder: [Self]) -> [CatalogTreeNode] {
    guard let comparator = sortOrder.first else { return nodes }
    return nodes.enumerated().sorted { lhs, rhs in
      let result = comparator.compare(lhs.element, rhs.element)
      return result == .orderedSame ? lhs.offset < rhs.offset : result == .orderedAscending
    }.map(\.element)
  }
}

extension CatalogTreeSnapshot {
  /// 来源不跨越子树，因此根层筛选保留完整层级。
  func roots(for source: NodeSource, sortedBy sortOrder: [ServerTableSort]) -> [CatalogTreeNode] {
    ServerTableSort.sorted(roots.filter { $0.source == source }, by: sortOrder)
  }

  /// 每层单独排序，再按展开状态生成 Table 行；不改变子树归属。
  func visibleRows(
    source: NodeSource, sortedBy sortOrder: [ServerTableSort], collapsed: Set<NodeID>
  ) -> [CatalogTreeRow] {
    var rows: [CatalogTreeRow] = []
    func append(_ nodes: [CatalogTreeNode], depth: Int) {
      for node in ServerTableSort.sorted(nodes, by: sortOrder) {
        rows.append(CatalogTreeRow(node: node, depth: depth))
        if !collapsed.contains(node.id) {
          append(node.childNodes, depth: depth + 1)
        }
      }
    }
    append(roots.filter { $0.source == source }, depth: 0)
    return rows
  }
}
