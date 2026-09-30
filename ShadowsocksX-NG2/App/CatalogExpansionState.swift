import Combine

/// 目录树折叠状态（纯窗口呈现状态）：组合根持有的长寿命对象。destination 切换
/// 会销毁分区子树里的 `@State`，折叠状态因此必须活在视图层级之外；服务器分区
/// 侧栏与首页目标树共用同一实例，一处收起、两处互见。语义=收起的分组身份集合，
/// 缺省全部展开；不落盘，进程重启回全展开基线。
@MainActor
final class CatalogExpansionState: ObservableObject {
  @Published private(set) var collapsedGroupIDs: Set<NodeID> = []

  func isCollapsed(_ id: NodeID) -> Bool {
    collapsedGroupIDs.contains(id)
  }

  func toggleCollapsed(_ id: NodeID) {
    if collapsedGroupIDs.contains(id) {
      collapsedGroupIDs.remove(id)
    } else {
      collapsedGroupIDs.insert(id)
    }
  }
}
