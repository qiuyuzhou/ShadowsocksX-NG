import SwiftUI

/// 侧栏树行（issue #41）：来源标识、有效性提示、活动目标标记与右键菜单。
/// 数据来自目录工作流 module 的树 projection；激活经 seam 的 typed command，
/// 活动目标标记由父视图传入（运行时事实，不进目录 projection）。删除一律
/// 交父视图确认弹窗（空手动组单次、非空二次，CONTEXT.md）。
struct SidebarRow: View {
  let node: CatalogTreeNode
  let workflow: CatalogWorkflow
  let activeTargetID: NodeID?
  let errors: ErrorAlertPresenter
  let onRename: (NodeID) -> Void
  let onNewGroup: (NodeID?) -> Void
  let onMove: (NodeID) -> Void
  let onDelete: (NodeID) -> Void

  private var isSubscription: Bool { node.source == .subscription }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: node.isGroup ? "folder" : "server.rack")
        .foregroundStyle(.secondary)
      Text(node.name)
        .foregroundStyle(node.isInvalid ? .secondary : .primary)
      if node.isInvalid {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help(
            node.invalidReasons.first.map {
              AppPresentation.message(
                for: ActivationFailure.invalidLeaf(node: node.id, reason: $0))
            } ?? "服务器存在已知阻塞问题")
      } else if node.invalidDescendantCount > 0 {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
          .help("包含 \(node.invalidDescendantCount) 个存在已知阻塞问题的服务器")
      }
      if isSubscription {
        Image(systemName: "arrow.triangle.2.circlepath")
          .foregroundStyle(.tertiary)
          .help("订阅节点：由远端管理")
      }
      if activeTargetID == node.id {
        Image(systemName: "bolt.fill")
          .foregroundStyle(.orange)
          .help("活动目标")
      }
    }
    .contextMenu { contextMenu }
  }

  @ViewBuilder
  private var contextMenu: some View {
    Button("激活") {
      Task {
        do {
          _ = try await workflow.activate(node.id)
        } catch {
          errors.present(error)
        }
      }
    }
    if !isSubscription {
      Divider()
      if node.isGroup {
        Button("重命名…") { onRename(node.id) }
      }
      Button("新建分组…") {
        onNewGroup(node.isGroup ? node.id : node.parentID)
      }
      Divider()
      Button("移动到…") { onMove(node.id) }
      Divider()
      Button("删除…", role: .destructive) {
        onDelete(node.id)
      }
    }
  }
}
