import SwiftUI

/// 分组详情（issue #32/#41）：名称编辑（手动组）、直接子节点数与激活入口。
/// 数据来自目录工作流 module 的树 projection；订阅固定分组名称由远端管理，
/// 只读。空组保留可编辑（可先搭结构再填内容）。
struct GroupDetailView: View {
  let workflow: CatalogWorkflow
  let groupID: NodeID
  let proxyController: ProxyRuntimeController
  let errors: ErrorAlertPresenter

  @State private var name = ""

  private var node: CatalogTreeNode? { workflow.tree.node(withID: groupID) }
  private var isManual: Bool { node?.isManual ?? false }

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
    .navigationTitle(workflow.displayName(for: groupID))
    .onAppear(perform: loadName)
    .onChange(of: groupID) { _, _ in loadName() }
  }

  private var directChildCount: Int { node?.childCount ?? 0 }
  private var invalidServerCount: Int { node?.invalidServerCount ?? 0 }
  private var serverCount: Int { node?.serverCount ?? 0 }
  private var validServerCount: Int { serverCount - invalidServerCount }

  private func loadName() {
    name = workflow.displayName(for: groupID)
  }

  private func saveName() {
    Task {
      do {
        try await workflow.renameGroup(groupID, to: name)
      } catch {
        errors.present(error)
      }
    }
  }
}
