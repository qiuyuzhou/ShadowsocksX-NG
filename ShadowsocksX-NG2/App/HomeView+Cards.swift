import SwiftUI

/// 「当前服务器」卡：只显示有服务器的分组；双击节点激活为当前服务器。
struct TargetTreeCard: View {
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  let onManageServers: () -> Void
  let errors: ErrorAlertPresenter

  /// 收起状态的目标分组（默认全部展开）。
  @State private var collapsedGroups: Set<NodeID> = []

  var body: some View {
    HomeCard(
      title: "当前服务器",
      subtitle: "只显示有服务器的分组，双击节点以设为当前服务器",
      trailing: {
        Button(action: onManageServers) {
          HStack(spacing: 4) {
            Text("管理服务器")
            Image(systemName: "arrow.right")
          }
          .font(.callout.weight(.medium))
        }
        .buttonStyle(.plain)
        .foregroundStyle(.tint)
      },
      content: {
        tree.padding(.top, 6)
      })
  }

  @ViewBuilder
  private var tree: some View {
    let groups = targetGroups
    if groups.isEmpty {
      Text("暂无服务器；在「服务器」分区导入 ss:// 链接或新建分组。")
        .font(.callout)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
    } else {
      VStack(alignment: .leading, spacing: 4) {
        ForEach(groups) { group in
          TargetGroupSection(
            group: group,
            activeTargetID: control.snapshot.activeTarget?.id,
            isCollapsed: isCollapsed(group.id),
            onToggle: { toggleCollapsed(group.id) },
            onActivate: activate)
        }
        ForEach(rootServers) { server in
          TargetServerRow(
            server: server,
            isActive: control.snapshot.activeTarget?.id == server.id,
            onActivate: activate)
        }
      }
    }
  }

  private func activate(_ id: NodeID) {
    Task {
      do {
        _ = try await workflow.activate(id)
      } catch {
        errors.present(error)
      }
    }
  }

  private func toggleCollapsed(_ id: NodeID) {
    if isCollapsed(id) {
      collapsedGroups.remove(id)
    } else {
      collapsedGroups.insert(id)
    }
  }

  private func isCollapsed(_ id: NodeID) -> Bool {
    collapsedGroups.contains(id)
  }

  /// 有服务器叶子的分组（递归收集；每组只呈现直属服务器叶子）。
  private var targetGroups: [TargetGroupInfo] {
    var groups: [TargetGroupInfo] = []
    func walk(_ nodes: [CatalogTreeNode]) {
      for node in nodes where node.isGroup {
        let servers = node.childNodes.filter { !$0.isGroup }
        if !servers.isEmpty {
          groups.append(
            TargetGroupInfo(
              id: node.id,
              name: node.name,
              sourceLabel: node.source == .subscription ? "订阅分组" : "手动分组",
              servers: servers))
        }
        walk(node.childNodes.filter { $0.isGroup })
      }
    }
    walk(workflow.tree.roots)
    return groups
  }

  /// 根层直接挂的服务器叶子（目录根层允许放服务器时兜底呈现）。
  private var rootServers: [CatalogTreeNode] {
    workflow.tree.roots.filter { !$0.isGroup }
  }
}

/// 单个目标分组：展开/收起头 + 直属服务器行。
struct TargetGroupSection: View {
  let group: TargetGroupInfo
  let activeTargetID: NodeID?
  let isCollapsed: Bool
  let onToggle: () -> Void
  let onActivate: (NodeID) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 4) {
      Button(action: onToggle) {
        HStack(spacing: 8) {
          Image(systemName: "chevron.right")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.tertiary)
            .rotationEffect(.degrees(isCollapsed ? 0 : 90))
          Image(systemName: "folder")
            .foregroundStyle(.secondary)
          VStack(alignment: .leading, spacing: 1) {
            Text(group.name)
              .font(.callout.weight(.medium))
              .foregroundStyle(.primary)
            Text("\(group.sourceLabel) · \(group.servers.count) 台")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
          Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      if !isCollapsed {
        VStack(alignment: .leading, spacing: 2) {
          ForEach(group.servers) { server in
            TargetServerRow(
              server: server,
              isActive: activeTargetID == server.id,
              onActivate: onActivate)
          }
        }
        .padding(.leading, 16)
      }
    }
    .padding(.vertical, 2)
  }
}

/// 目标树里的服务器行：双击激活，活动目标勾选标记。
struct TargetServerRow: View {
  let server: CatalogTreeNode
  let isActive: Bool
  let onActivate: (NodeID) -> Void

  var body: some View {
    HStack(spacing: 10) {
      RoundedRectangle(cornerRadius: 6, style: .continuous)
        .fill(.quaternary)
        .frame(width: 28, height: 28)
        .overlay {
          Image(systemName: "server.rack")
            .font(.system(size: 12))
            .foregroundStyle(.tint)
        }
      VStack(alignment: .leading, spacing: 1) {
        Text(server.name)
          .font(.callout.weight(isActive ? .semibold : .regular))
          .foregroundStyle(server.isInvalid ? .secondary : .primary)
        Text(server.source == .subscription ? "订阅节点" : "手动服务器")
          .font(.caption)
          .foregroundStyle(.secondary)
      }
      Spacer(minLength: 0)
      if server.isInvalid {
        Image(systemName: "exclamationmark.triangle.fill")
          .foregroundStyle(.orange)
          .help("该服务器存在已知阻塞问题，激活会被点名拒绝")
      }
      Image(systemName: "checkmark")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.tint)
        .opacity(isActive ? 1 : 0)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      isActive ? Color.accentColor.opacity(0.10) : Color.clear,
      in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .contentShape(Rectangle())
    .onTapGesture(count: 2) {
      onActivate(server.id)
    }
    .help("双击设为当前服务器")
  }
}

/// 「快速操作」卡：更新全部订阅、复制终端 HTTP 代理导出行。
struct QuickActionCard: View {
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  let clipboard: any TextClipboard
  let errors: ErrorAlertPresenter

  @State private var isRefreshingAll = false

  var body: some View {
    HomeCard(
      title: "快速操作",
      subtitle: nil,
      trailing: { EmptyView() },
      content: {
        VStack(spacing: 10) {
          QuickActionButton(
            icon: "arrow.triangle.2.circlepath",
            title: isRefreshingAll ? "正在更新…" : "更新全部订阅",
            help: nil,
            action: refreshAll
          )
          .disabled(workflow.subscriptions.isEmpty || isRefreshingAll)
          QuickActionButton(
            icon: "doc.on.doc",
            title: "复制终端 HTTP 代理指令",
            help: copyHelp,
            action: copyHTTPExport
          )
          if isRefreshingAll {
            ProgressView()
              .controlSize(.small)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.top, 6)
      })
  }

  private var copyHelp: String? {
    "复制可在 shell 中 source 的 http/https 代理导出行"
  }

  private func refreshAll() {
    isRefreshingAll = true
    Task {
      await workflow.refreshAllSubscriptions()
      isRefreshingAll = false
    }
  }

  private func copyHTTPExport() {
    let line = control.snapshot.httpExport.copyableLine
    do {
      try clipboard.write(line)
    } catch {
      errors.present(error)
    }
  }
}

/// 目标分组的呈现模型（票 #54）：名称、来源说明与直属服务器叶子。
struct TargetGroupInfo: Identifiable {
  let id: NodeID
  let name: String
  let sourceLabel: String
  let servers: [CatalogTreeNode]
}
