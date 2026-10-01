import Combine
import Foundation

struct HomeServerTreeRow: Identifiable {
  let node: CatalogTreeNode
  let depth: Int
  var id: NodeID { node.id }
}

/// 首页独立的浏览状态。选择与折叠不改变目录或运行时活动目标。
@MainActor
final class HomeServerListState: ObservableObject {
  enum Navigation { case upward, downward, left, right }
  @Published private(set) var tree = CatalogTreeSnapshot(roots: [])
  @Published private(set) var selection: NodeID?
  @Published private(set) var collapsedGroupIDs: Set<NodeID> = []
  private var knownGroupIDs: Set<NodeID> = []
  private var didInitializeSelection = false
  private let defaults: UserDefaults
  private static let expansionKey = "homeServerList.expansion"

  private struct ExpansionPreferences: Codable {
    let known: Set<NodeID>
    let collapsed: Set<NodeID>
  }

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    if let data = defaults.data(forKey: Self.expansionKey),
      let saved = try? JSONDecoder().decode(ExpansionPreferences.self, from: data)
    {
      knownGroupIDs = saved.known
      collapsedGroupIDs = saved.collapsed
    }
  }

  var visibleRows: [HomeServerTreeRow] {
    var rows: [HomeServerTreeRow] = []
    func walk(_ nodes: [CatalogTreeNode], depth: Int) {
      for node in nodes {
        rows.append(HomeServerTreeRow(node: node, depth: depth))
        if node.isGroup, !collapsedGroupIDs.contains(node.id) {
          walk(node.childNodes, depth: depth + 1)
        }
      }
    }
    walk(tree.roots, depth: 0)
    return rows
  }

  func update(tree: CatalogTreeSnapshot, activeTargetID: NodeID?) {
    let previousTree = self.tree
    self.tree = tree
    var currentGroups: Set<NodeID> = []
    func walk(_ nodes: [CatalogTreeNode], depth: Int) {
      for node in nodes where node.isGroup {
        currentGroups.insert(node.id)
        if knownGroupIDs.insert(node.id).inserted, depth > 0 {
          collapsedGroupIDs.insert(node.id)
        }
        walk(node.childNodes, depth: depth + 1)
      }
    }
    walk(tree.roots, depth: 0)
    knownGroupIDs.formIntersection(currentGroups)
    collapsedGroupIDs.formIntersection(currentGroups)
    if !didInitializeSelection, !tree.isEmpty {
      selection = activeTargetID.flatMap { tree.containsNode($0) ? $0 : nil }
      didInitializeSelection = true
    } else if let selection, !tree.containsNode(selection) {
      self.selection = nil
    } else if let selection, tree != previousTree,
      let visibleAncestor = ancestorIDs(for: selection).reversed().first(where: {
        collapsedGroupIDs.contains($0)
      })
    {
      self.selection = visibleAncestor
    }
    saveExpansion()
  }

  func select(_ id: NodeID) {
    guard visibleRows.contains(where: { $0.id == id }) else { return }
    selection = id
  }

  /// 行内按钮与 Return 共用门禁；隐藏、无效和已激活目标均不发出命令。
  func activationTarget(
    activeTargetID: NodeID?, eligibility: ActivationEligibility?
  ) -> NodeID? {
    guard let selection, selection != activeTargetID,
      eligibility?.canActivate == true,
      visibleRows.contains(where: { $0.id == selection })
    else { return nil }
    return selection
  }

  /// 明确定位才展开祖先；启动时隐藏的活动项保持选中而不自动展开。
  func locate(_ id: NodeID) {
    guard tree.containsNode(id) else { return }
    collapsedGroupIDs.subtract(ancestorIDs(for: id))
    selection = id
    saveExpansion()
  }

  func toggleGroup(_ id: NodeID) {
    guard tree.node(withID: id)?.isGroup == true else { return }
    if !collapsedGroupIDs.insert(id).inserted {
      collapsedGroupIDs.remove(id)
    } else if let selection, ancestorIDs(for: selection).contains(id) {
      self.selection = id
    }
    saveExpansion()
  }

  func ancestorIDs(for id: NodeID) -> [NodeID] {
    var result: [NodeID] = []
    var parent = tree.node(withID: id)?.parentID
    while let id = parent {
      result.append(id)
      parent = tree.node(withID: id)?.parentID
    }
    return result
  }

  func navigate(_ direction: Navigation) {
    let rows = visibleRows
    guard !rows.isEmpty else { return }
    guard let selection, let index = rows.firstIndex(where: { $0.id == selection }) else {
      if direction == .upward || direction == .downward {
        self.selection = direction == .upward ? rows.last?.id : rows.first?.id
      }
      return
    }
    let node = rows[index].node
    switch direction {
    case .upward:
      self.selection = rows[max(0, index - 1)].id
    case .downward:
      self.selection = rows[min(rows.count - 1, index + 1)].id
    case .left:
      collapseOrSelectParent(node)
    case .right:
      expandOrSelectChild(node)
    }
  }

  private func collapseOrSelectParent(_ node: CatalogTreeNode) {
    if node.isGroup, !collapsedGroupIDs.contains(node.id) {
      toggleGroup(node.id)
    } else if let parent = node.parentID {
      selection = parent
    }
  }

  private func expandOrSelectChild(_ node: CatalogTreeNode) {
    if node.isGroup, collapsedGroupIDs.contains(node.id) {
      toggleGroup(node.id)
    } else if let child = node.childNodes.first {
      selection = child.id
    }
  }

  private func saveExpansion() {
    let preferences = ExpansionPreferences(known: knownGroupIDs, collapsed: collapsedGroupIDs)
    if let data = try? JSONEncoder().encode(preferences) {
      defaults.set(data, forKey: Self.expansionKey)
    }
  }
}
