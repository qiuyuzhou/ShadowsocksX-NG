import SwiftUI

/// 侧栏树行（issue #41）：来源标识、有效性提示、活动目标标记与右键菜单。
/// 数据来自目录工作流 module 的树 projection；服务器/分组不再拥有独立的启
/// 用/停用状态，激活时由状态机按有效性展开。
struct SidebarRow: View {
  let node: CatalogTreeNode
  let workflow: CatalogWorkflow
  let proxyController: ProxyRuntimeController
  let errors: ErrorAlertPresenter
  let onRename: (NodeID) -> Void
  let onNewGroup: (NodeID?) -> Void
  let onMove: (NodeID) -> Void
  let onDelete: (NodeID) -> Void
  /// 直接删除完成后的回调（携带被删身份集合；UI 据此清除失效选择）。
  let onRemoved: (Set<NodeID>) -> Void

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
          .help(node.validation?.issues.first?.presentedReason ?? "服务器存在已知阻塞问题")
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
      if proxyController.activeTargetID == node.id {
        Image(systemName: "bolt.fill")
          .foregroundStyle(.orange)
          .help("活动目标")
      }
    }
    .contextMenu { contextMenu }
  }

  /// 空手动组直接删除；服务器与非空手动组走确认弹窗（issue #32）。
  private var isEmptyManualGroup: Bool {
    node.isGroup && node.isManual && node.childNodes.isEmpty
  }

  @ViewBuilder
  private var contextMenu: some View {
    Button("激活") {
      Task { await proxyController.activate(node.id) }
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
        if isEmptyManualGroup {
          Task {
            do {
              let outcome = try await workflow.remove(node.id)
              onRemoved(outcome.removedNodeIDs)
            } catch {
              errors.present(error)
            }
          }
        } else {
          onDelete(node.id)
        }
      }
    }
  }
}
