import SwiftUI

/// 侧栏树行：来源标识、有效性提示、活动目标标记与右键菜单。
/// 服务器/分组不再拥有独立的启用/停用状态；激活时由状态机按有效性展开。
struct SidebarRow: View {
  let node: SidebarNode
  let viewModel: CatalogViewModel
  let proxyController: ProxyRuntimeController
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
      if proxyController.machine.activeTargetID == node.id {
        Image(systemName: "bolt.fill")
          .foregroundStyle(.orange)
          .help("活动目标")
      }
    }
    .contextMenu { contextMenu }
  }

  /// 空手动组直接删除；服务器与非空手动组走确认弹窗（issue #32）。
  private var isEmptyManualGroup: Bool {
    node.isGroup && node.source == .manual && (node.children?.isEmpty ?? true)
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
        onNewGroup(node.isGroup ? node.id : viewModel.parentID(of: node.id))
      }
      Divider()
      Button("移动到…") { onMove(node.id) }
      Divider()
      Button("删除…", role: .destructive) {
        if isEmptyManualGroup {
          Task {
            do {
              try await viewModel.remove(node.id)
            } catch {
              viewModel.presentedError = error.presentableMessage
            }
          }
        } else {
          onDelete(node.id)
        }
      }
    }
  }
}
