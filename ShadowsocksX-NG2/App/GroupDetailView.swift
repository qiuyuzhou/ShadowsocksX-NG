import SwiftUI

/// 分组详情（issue #32）：名称编辑（手动组）、直接子节点数与激活入口。
/// 订阅固定分组名称由远端管理，只读。空组保留可编辑（可先搭结构再填内容）。
struct GroupDetailView: View {
  let viewModel: CatalogViewModel
  let groupID: NodeID
  let proxyController: ProxyRuntimeController

  @State private var name = ""

  private var entry: CatalogEntry? { viewModel.entry(for: groupID) }
  private var isManual: Bool { entry?.source == .manual }

  var body: some View {
    Form {
      Section("分组") {
        TextField("名称", text: $name)
          .disabled(!isManual)
        if isManual {
          Button("保存名称") { saveName() }
        }
      }
      Section {
        LabeledContent("直接子节点", value: "\(directChildCount)")
        if invalidServerCount > 0 {
          LabeledContent("已知无效服务器", value: "\(invalidServerCount)")
        }
        LabeledContent("来源", value: isManual ? "手动" : "订阅")
        Button {
          Task { await proxyController.activate(groupID) }
        } label: {
          Label("激活此分组", systemImage: "bolt.fill")
        }
        .disabled(validServerCount == 0)
        if directChildCount == 0 {
          Text("空分组保留可编辑，但不能激活。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if validServerCount == 0 {
          Text("分组中没有可激活的有效服务器。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        } else if invalidServerCount > 0 {
          Text("激活时将跳过 \(invalidServerCount) 个存在已知阻塞问题的服务器。")
            .font(.footnote)
            .foregroundStyle(.secondary)
        }
      }
    }
    .formStyle(.grouped)
    .navigationTitle(viewModel.displayName(for: groupID))
    .onAppear(perform: loadName)
    .onChange(of: groupID) { _, _ in loadName() }
  }

  private var directChildCount: Int {
    (try? viewModel.catalog.children(of: groupID))?.count ?? 0
  }

  private var invalidServerCount: Int {
    groupNode?.invalidServerCount ?? 0
  }

  private var validServerCount: Int {
    serverCount - invalidServerCount
  }

  private var serverCount: Int {
    guard let node = groupNode else {
      return 0
    }
    return countServers(in: node)
  }

  private var groupNode: SidebarNode? {
    func find(_ nodes: [SidebarNode]) -> SidebarNode? {
      for node in nodes {
        if node.id == groupID { return node }
        if let match = find(node.children ?? []) { return match }
      }
      return nil
    }
    return find(viewModel.sidebarNodes())
  }

  private func countServers(in node: SidebarNode) -> Int {
    if node.isGroup {
      return (node.children ?? []).reduce(0) { $0 + countServers(in: $1) }
    }
    return 1
  }

  private func loadName() {
    name = viewModel.displayName(for: groupID)
  }

  private func saveName() {
    Task {
      do {
        try await viewModel.renameGroup(groupID, to: name)
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }
}
