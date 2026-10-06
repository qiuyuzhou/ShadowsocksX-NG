import SwiftUI

/// 新建位置只允许从当前组逐级上移；选中祖先后，以新位置重建菜单。
struct CreationLocationField: View {
  let tree: CatalogTreeSnapshot
  @Binding var parent: NodeID?

  private var ancestors: [CatalogTreeNode] {
    var nodes: [CatalogTreeNode] = []
    var id = parent
    while let currentID = id, let node = tree.node(withID: currentID) {
      nodes.append(node)
      id = node.parentID
    }
    return nodes
  }

  var body: some View {
    let nodes = ancestors
    Picker("位置", selection: $parent) {
      ForEach(Array(nodes.enumerated()), id: \.element.id) { depth, node in
        Text(verbatim: String(repeating: "  ", count: depth) + node.name)
          .lineLimit(1)
          .truncationMode(.tail)
          .tag(Optional(node.id))
      }
      (Text(verbatim: String(repeating: "  ", count: nodes.count)) + Text("所有服务器"))
        .tag(nil as NodeID?)
    }
    .pickerStyle(.menu)
    .lineLimit(1)
    .truncationMode(.tail)
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}
