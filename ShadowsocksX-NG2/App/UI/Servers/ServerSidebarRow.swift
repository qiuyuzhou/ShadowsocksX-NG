import SwiftUI

/// 服务器子视图侧栏的树行（issue #41）：来源标识、有效性提示、活动目标标记
/// 与右键菜单。数据来自目录工作流 module 的树 projection；激活经 seam 的
/// typed command，活动目标标记由父视图传入（运行时事实，不进目录 projection）。
/// 删除一律交父视图确认弹窗（空手动组单次、非空二次，GLOSSARY.md）。
struct ServerSidebarRow: View {
  let node: CatalogTreeNode
  let workflow: CatalogWorkflow
  /// 激活反馈共享状态：命令经它发出（单飞互斥、结果记录在会话反馈里）。
  let activation: ActivationFeedbackState
  let activeTargetID: NodeID?
  let errors: ErrorAlertPresenter
  let onEdit: (NodeID) -> Void
  let onRename: (NodeID) -> Void
  let onNewGroup: (NodeID?) -> Void
  let onMove: (NodeID) -> Void
  let onDuplicate: (NodeID) -> Void
  let onDelete: (NodeID) -> Void
  let onExport: (NodeID) -> Void

  private var isSubscription: Bool { node.source == .subscription }

  var body: some View {
    HStack(spacing: 6) {
      Image(systemName: node.isGroup ? "folder" : "server.rack")
        .foregroundStyle(.secondary)
      VStack(alignment: .leading, spacing: 1) {
        Text(node.name)
          .foregroundStyle(node.isInvalid ? .secondary : .primary)
        if node.isGroup {
          // 分组行尾数量说明（票 #55）：原型「手动分组 · N 项」口径。
          Text("\(node.isManual ? "手动分组" : "订阅分组") · \(node.childCount) 项")
            .font(.caption)
            .foregroundStyle(.tertiary)
        }
      }
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
      Task { @MainActor in
        do {
          let outcome = try await activation.activate(node.id, via: workflow)
          // 右键菜单即关、无内联反馈面：原子拒绝点名弹窗（typed 原因随
          // 结果返回）；单飞忽略（nil）不呈现。
          if case .rejectedActivation(let failure)? = outcome {
            errors.present(failure)
          }
        } catch {
          errors.present(error)
        }
      }
    }
    if node.isGroup {
      Divider()
      Button("导出为 SIP-008 JSON…") { onExport(node.id) }
        .disabled(!node.containsServerConfiguration)
    }
    Divider()
    Button {
      onDuplicate(node.id)
    } label: {
      Label("复制", systemImage: "plus.square.on.square")
    }
    .disabled(!workflow.canDuplicate(node.id))
    if !isSubscription {
      Divider()
      if node.isGroup {
        Button("重命名…") { onRename(node.id) }
      } else {
        Button("编辑…") { onEdit(node.id) }
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
