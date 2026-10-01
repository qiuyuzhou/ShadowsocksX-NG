import SwiftUI

/// 「当前服务器」卡：只显示有服务器的分组；双击节点激活为当前服务器。
struct TargetTreeCard: View {
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  /// 分组折叠状态：组合根持有的共享对象，与服务器分区侧栏同源，跨分区切换存续。
  @ObservedObject var expansion: CatalogExpansionState
  let onManageServers: () -> Void
  let errors: ErrorAlertPresenter

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
            isCollapsed: expansion.isCollapsed(group.id),
            onToggle: { expansion.toggleCollapsed(group.id) },
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
          Text(group.name)
            .font(.body.weight(.medium))
            .foregroundStyle(.primary)
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
      Text(server.name)
        .font(.body.weight(isActive ? .semibold : .regular))
        .foregroundStyle(server.isInvalid ? .secondary : .primary)
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

/// 「复制代理环境变量设置命令」卡：按所选 shell 格式复制 HTTP 与 SOCKS 环境变量。
/// 非「仅本机」监听方式下先以单选下拉框选择命令地址（issue #72），两种 shell
/// 的全部代理端点共用该选择；仅本机方式隐藏下拉框并始终使用回环地址。
struct TerminalProxyEnvironmentCard: View {
  @ObservedObject var control: ProxyControlWorkflow
  let clipboard: any TextClipboard
  let errors: ErrorAlertPresenter

  @State private var copiedShell: TerminalCommandShell?
  @State private var feedbackTask: Task<Void, Never>?

  var body: some View {
    HomeCard(
      title: "复制代理环境变量设置命令",
      subtitle: nil,
      trailing: { EmptyView() },
      content: {
        VStack(spacing: 10) {
          if control.snapshot.commandAddressPicker.isVisible {
            Picker("命令地址", selection: commandAddressBinding) {
              ForEach(
                control.snapshot.commandAddressPicker.candidates, id: \.identity
              ) { candidate in
                Text(candidate.label).tag(candidate)
              }
            }
            .pickerStyle(.menu)
            .frame(maxWidth: .infinity, alignment: .leading)
          }
          commandButton(for: .zshBash)
          commandButton(for: .fish)
        }
        .padding(.top, 6)
      }
    )
    .onAppear {
      control.refreshCommandAddresses()
    }
    .onDisappear {
      feedbackTask?.cancel()
      feedbackTask = nil
      copiedShell = nil
    }
  }

  private var commandAddressBinding: Binding<TerminalCommandAddress> {
    Binding(
      get: { control.snapshot.commandAddressPicker.selected },
      set: { address in control.selectCommandAddress(address) })
  }

  private func commandButton(for shell: TerminalCommandShell) -> some View {
    let isCopied = copiedShell == shell
    return Button {
      copy(shell)
    } label: {
      HStack(spacing: 10) {
        Image(systemName: isCopied ? "checkmark" : "doc.on.doc")
          .foregroundStyle(isCopied ? Color.green : Color.accentColor)
        Text(isCopied ? "已复制" : shell.title)
          .font(.callout.weight(.medium))
          .foregroundStyle(.primary)
          .lineLimit(1)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 12)
      .padding(.vertical, 10)
      .frame(maxWidth: .infinity, alignment: .leading)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .background(
      .quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8, style: .continuous)
    )
    .help(shell.command(from: control.snapshot.terminalProxyEnvironmentCommands))
  }

  private func copy(_ shell: TerminalCommandShell) {
    // 复制前刷新（issue #72）：失效选择回退后的命令即剪贴板内容，与按钮
    // 提示保持同一选择。
    let commands = control.refreshCommandAddresses()
    do {
      try clipboard.write(shell.command(from: commands))
      feedbackTask?.cancel()
      copiedShell = shell
      feedbackTask = Task { @MainActor in
        try? await Task.sleep(nanoseconds: 1_500_000_000)
        guard !Task.isCancelled, copiedShell == shell else { return }
        copiedShell = nil
        feedbackTask = nil
      }
    } catch {
      feedbackTask?.cancel()
      feedbackTask = nil
      copiedShell = nil
      errors.present(error)
    }
  }
}

private enum TerminalCommandShell: Equatable {
  case zshBash
  case fish

  var title: String {
    switch self {
    case .zshBash: "zsh / bash"
    case .fish: "fish"
    }
  }

  func command(from commands: TerminalProxyEnvironmentCommands) -> String {
    switch self {
    case .zshBash: commands.zshBash
    case .fish: commands.fish
    }
  }
}

/// 「快速操作」卡：更新全部订阅。
struct QuickActionCard: View {
  @ObservedObject var workflow: CatalogWorkflow

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
          if isRefreshingAll {
            ProgressView()
              .controlSize(.small)
              .frame(maxWidth: .infinity, alignment: .leading)
          }
        }
        .padding(.top, 6)
      })
  }

  private func refreshAll() {
    isRefreshingAll = true
    Task {
      await workflow.refreshAllSubscriptions()
      isRefreshingAll = false
    }
  }

}

/// 目标分组的呈现模型（票 #54）：名称与直属服务器叶子。
struct TargetGroupInfo: Identifiable {
  let id: NodeID
  let name: String
  let servers: [CatalogTreeNode]
}
