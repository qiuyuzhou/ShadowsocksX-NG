import SwiftUI

/// 「移动到」表单（issue #41）：目的地由 seam 的 `moveDestinations` 提供——
/// 目录根与除自身子树外的全部手动组；跨来源与成环由领域层最终拒绝。
struct MoveNodeSheet: View {
  let workflow: CatalogWorkflow
  let errors: ErrorAlertPresenter
  let nodeID: NodeID
  @Environment(\.dismiss) private var dismiss

  @State private var destination: NodeID?

  private struct Destination: Identifiable {
    let id: NodeID?
    let title: String
  }

  private var destinations: [Destination] {
    workflow.moveDestinations(for: nodeID).map { item in
      let indent = String(repeating: "    ", count: item.depth)
      return Destination(id: item.id, title: indent + item.name)
    }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("把「\(workflow.displayName(for: nodeID))」移动到：")
        .font(.callout)
      Picker(
        "目的地",
        selection: Binding(
          get: { destination ?? destinations.first?.id },
          set: { destination = $0 }
        )
      ) {
        ForEach(destinations) { target in
          Text(target.title).tag(target.id as NodeID?)
        }
      }
      .pickerStyle(.radioGroup)
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("移动") { move() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 380)
  }

  private func move() {
    Task {
      do {
        try await workflow.move(nodeID, to: destination)
        dismiss()
      } catch {
        errors.present(error)
      }
    }
  }
}
