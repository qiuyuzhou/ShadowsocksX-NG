import SwiftUI

/// 首页分区（地图 #52，票 #54）：代理模式切换、运行控制、当前服务器目标树
/// 与快速操作。模式与两个开关（agent/系统代理，issue #60）走代理控制工作流
/// 的整体 snapshot；目标树与激活走目录工作流 projection 与 `activate`；复制
/// HTTP 导出是 UI 副作用。当前选择器保留 PAC 和全局模式，并加入 ACL 直连。
struct HomeView: View {
  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var control: ProxyControlWorkflow
  let clipboard: any TextClipboard
  let onManageServers: () -> Void
  let errors: ErrorAlertPresenter

  var body: some View {
    ScrollView {
      HStack(alignment: .top, spacing: 20) {
        VStack(spacing: 20) {
          ModeCard(control: control)
          TargetTreeCard(
            workflow: workflow,
            control: control,
            onManageServers: onManageServers,
            errors: errors)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        VStack(spacing: 20) {
          RuntimeControlCard(control: control)
          QuickActionCard(
            workflow: workflow, control: control, clipboard: clipboard, errors: errors)
        }
        .frame(width: 300)
      }
      .padding(.leading, 28)
      .padding(.trailing, 32)
      .padding(.top, 24)
      .padding(.bottom, 36)
    }
  }
}

/// 「运行控制」卡（issue #60）：agent 与系统代理两个开关并排，绑定同一
/// snapshot 的持久化意图；各自呈现运行状态/实际应用与点名原因。两个开关
/// 互不代替：关闭系统代理不影响本地监听，关闭 agent 先恢复系统设置。
private struct RuntimeControlCard: View {
  @ObservedObject var control: ProxyControlWorkflow

  var body: some View {
    let summary = StatusMenuModel.summary(from: control.snapshot)
    HomeCard(
      title: "运行控制",
      subtitle: "后台代理与系统代理相互独立",
      trailing: { EmptyView() },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Toggle("后台代理", isOn: agentBinding)
                .toggleStyle(.switch)
              Spacer(minLength: 0)
              Text(summary.status)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            if let detail = summary.detail {
              Text(detail)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
          Divider()
          VStack(alignment: .leading, spacing: 6) {
            HStack {
              Toggle("设置系统代理", isOn: systemProxyBinding)
                .toggleStyle(.switch)
              Spacer(minLength: 0)
              Text(summary.systemProxyStateLabel)
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            Text(systemProxyHint)
              .font(.caption)
              .foregroundStyle(.secondary)
              .fixedSize(horizontal: false, vertical: true)
            if let systemProxyDetail = summary.systemProxyDetail {
              Text(systemProxyDetail)
                .font(.caption)
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
            }
          }
        }
        .padding(.top, 6)
      })
  }

  private var agentBinding: Binding<Bool> {
    Binding(
      get: { control.snapshot.agentIntentEnabled },
      set: { enabled in Task { await control.setAgentEnabled(enabled) } })
  }

  private var systemProxyBinding: Binding<Bool> {
    Binding(
      get: { control.snapshot.systemProxyIntentEnabled },
      set: { enabled in Task { await control.setSystemProxyEnabled(enabled) } })
  }

  private var systemProxyHint: String {
    let exitRequirement =
      control.snapshot.proxyMode == .direct
      ? "直连模式不依赖活动服务器"
      : "其他模式需要可用的活动服务器"
    return switch control.snapshot.systemProxyApplication {
    case .idle:
      "开启后让 macOS 系统代理指向本地入口；\(exitRequirement)"
    case .pending:
      "已请求接管，等待本地入口就绪；\(exitRequirement)"
    case .applied:
      "系统代理已指向本地入口；关闭只恢复 NG2 持有的系统设置"
    case .failed:
      "应用失败，原因见下方"
    }
  }
}

/// 「代理模式」卡：可用模式切换（Domain 单点策略投影）+ 规则子选项 + 模式说明 + 当前徽标。
private struct ModeCard: View {
  @ObservedObject var control: ProxyControlWorkflow

  var body: some View {
    HomeCard(
      title: "代理模式",
      subtitle: "选择系统代理接管方式",
      trailing: { ModeBadge(label: modeBadgeLabel) },
      content: {
        VStack(alignment: .leading, spacing: 14) {
          Picker("代理模式", selection: modeBinding) {
            ForEach(control.snapshot.availableModes, id: \.self) { mode in
              Text(mode.label).tag(mode)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          .frame(maxWidth: 480, alignment: .leading)
          if control.snapshot.proxyMode == .rule {
            Picker("未匹配默认动作", selection: ruleDefaultActionBinding) {
              ForEach(RuleDefaultAction.allCases, id: \.self) { action in
                Text(action.label).tag(action)
              }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 480, alignment: .leading)
          }
          Text(modeDescription(control.snapshot.proxyMode))
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, 6)
      })
  }

  private var modeBadgeLabel: String {
    let mode = control.snapshot.proxyMode
    if mode == .rule {
      return "\(mode.label) · \(control.snapshot.ruleDefaultAction.label)"
    }
    return mode.label
  }

  private var modeBinding: Binding<ProxyMode> {
    Binding(
      get: { control.snapshot.proxyMode },
      set: { mode in
        Task { await control.setProxyMode(mode) }
      })
  }

  private var ruleDefaultActionBinding: Binding<RuleDefaultAction> {
    Binding(
      get: { control.snapshot.ruleDefaultAction },
      set: { action in
        Task { await control.setRuleDefaultAction(action) }
      })
  }

  private func modeDescription(_ mode: ProxyMode) -> String {
    switch mode {
    case .rule:
      "按内置中国域名规则在代理与直连间选择；未匹配目标走默认动作。"
    case .pac:
      "根据规则自动决定直连或通过代理，适合日常使用。"
    case .global:
      "所有系统代理流量通过本地 SOCKS5 端点转发，不使用规则分流。"
    case .direct:
      "通过本地 SOCKS 与 HTTP 入口直连，不使用 Shadowsocks 服务器。"
    }
  }
}

/// 「当前服务器」卡：只显示有服务器的分组；双击节点激活为当前服务器。
private struct TargetTreeCard: View {
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
private struct TargetGroupSection: View {
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
private struct TargetServerRow: View {
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
private struct QuickActionCard: View {
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
private struct TargetGroupInfo: Identifiable {
  let id: NodeID
  let name: String
  let sourceLabel: String
  let servers: [CatalogTreeNode]
}
