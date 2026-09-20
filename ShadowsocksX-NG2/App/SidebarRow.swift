import SwiftUI

/// 侧栏树行：行内启用 checkbox、来源标识、活动目标标记与右键菜单。
/// 订阅行只暴露激活/启停（结构操作整体缺席，领域层兜底拒绝）。
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
      Toggle("", isOn: enableBinding)
        .labelsHidden()
        .toggleStyle(.checkbox)
      Image(systemName: node.isGroup ? "folder" : "server.rack")
        .foregroundStyle(.secondary)
      Text(node.name)
        .foregroundStyle(node.effectivelyEnabled ? .primary : .secondary)
      if isSubscription {
        Image(systemName: "arrow.triangle.2.circlepath")
          .foregroundStyle(.tertiary)
          .help("订阅节点：由远端管理，仅启用开关可调")
      }
      if proxyController.machine.activeTargetID == node.id {
        Image(systemName: "bolt.fill")
          .foregroundStyle(.orange)
          .help("活动目标")
      }
    }
    .contextMenu { contextMenu }
  }

  private var enableBinding: Binding<Bool> {
    Binding(
      get: { viewModel.entry(for: node.id)?.enabled ?? false },
      set: { newValue in
        Task {
          do {
            try await viewModel.setEnabled(node.id, newValue)
          } catch {
            viewModel.presentedError = error.presentableMessage
          }
        }
      })
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
    Button(node.enabled ? "停用" : "启用") {
      enableBinding.wrappedValue.toggle()
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
