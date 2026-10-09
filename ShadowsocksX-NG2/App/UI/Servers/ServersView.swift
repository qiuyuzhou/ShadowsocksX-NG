import SwiftUI

/// 服务器目录、只读详情与分组命令；本视图持有新建／编辑 sheet 和确认弹窗。
/// selection 由主窗口绑定，订阅删除可清除失效选择。
struct ServersView: View {

  @ObservedObject var workflow: CatalogWorkflow
  /// 激活反馈共享状态（三激活入口共用，单飞互斥）：侧栏右键与分组详情的
  /// 激活命令都经它发出。
  let activation: ActivationFeedbackState
  /// 活动目标标记：父视图传入的运行时事实，不进目录 projection（与
  /// ServerTableNameCell/ServerDetailView 的传参先例同法）。
  let activeTargetID: NodeID?
  @Binding var selection: NodeID?
  @Binding var source: NodeSource
  @Binding var sortOrder: [ServerTableSort]
  /// 服务器管理的展开状态跨工作区页面切换保留，不落盘。
  @ObservedObject var expansion: CatalogExpansionState
  let clipboard: any TextClipboard
  let imageClipboard: any ImageClipboard
  let configurationGroupFileExporter: any ConfigurationGroupFileExporter
  let qrImageSaver: any QrImageSaver

  /// 共享错误弹窗呈现（UI 持有；typed error → 本地化文案的呈现边缘）。
  /// 非 private：ServersView+Share.swift 扩展经它呈现分享失败。
  @StateObject var errors = ErrorAlertPresenter()

  // 纯窗口状态（issue #41）：selection/sheet/alert 不进目录 module。
  @State private var renameTarget: NodeID?
  @State private var newGroupParent: NodeID?
  @State private var isPresentingNewGroup = false
  @State private var serverFormOperation: ServerFormSheet.Operation?
  @State private var deleteTarget: NodeID?
  @State private var dropState = ServerTableDropState()
  // 分享 popover 打开时冻结载荷、顶部资料与建议文件名。
  @State var shareContext: ShareContext?

  var body: some View {
    NavigationSplitView {
      sourceSidebar
        .navigationSplitViewColumnWidth(min: 120, ideal: 150, max: 200)
    } content: {
      serverTable
        .navigationSplitViewColumnWidth(min: 380, ideal: 520)
    } detail: {
      serverDetailPane
        .frame(minWidth: 320, maxWidth: .infinity, maxHeight: .infinity)
    }
    .navigationSplitViewStyle(.balanced)
    .frame(minHeight: 420)
    .sheet(
      item: Binding(
        get: { renameTarget.map(NodeContext.init) },
        set: { renameTarget = $0?.nodeID })
    ) { context in
      RenameGroupSheet(workflow: workflow, errors: errors, nodeID: context.nodeID)
    }
    .sheet(isPresented: $isPresentingNewGroup) {
      NewGroupSheet(
        workflow: workflow, errors: errors, parent: newGroupParent,
        onCreated: selectCreatedNode)
    }
    .presentingErrors(errors)
    .confirmationDialog(
      deleteTitle,
      isPresented: Binding(
        get: { deleteTarget != nil },
        set: { if !$0 { deleteTarget = nil } }),
      titleVisibility: .visible
    ) {
      Button("删除", role: .destructive) { commitDelete() }
      Button("取消", role: .cancel) { deleteTarget = nil }
    } message: {
      Text(deleteMessage)
    }
    .sheet(item: $serverFormOperation) { operation in
      ServerFormSheet(
        workflow: workflow, operation: operation,
        onCreated: selectCreatedNode)
    }
    // 切换选中项时立即收起分享，避免显示旧服务器。
    .onChange(of: selection) {
      shareContext = nil
    }
  }

  private var sourceSidebar: some View {
    List(
      selection: Binding<NodeSource?>(
        get: { source },
        set: { value in
          guard let value, value != source else { return }
          selection = nil
          source = value
        })
    ) {
      Label("本地", systemImage: "internaldrive").tag(NodeSource.manual)
      Label("订阅", systemImage: "arrow.triangle.2.circlepath").tag(NodeSource.subscription)
    }
    .listStyle(.sidebar)
  }

  private var serverTable: some View {
    let rows = workflow.tree.visibleRows(
      source: source, sortedBy: sortOrder, collapsed: expansion.collapsedGroupIDs)
    let depths = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.depth) })
    return Table(
      of: CatalogTreeNode.self, selection: $selection,
      sortOrder: Binding(get: { sortOrder }, set: { sortOrder = Array($0.prefix(1)) })
    ) {
      TableColumn("名称", sortUsing: ServerTableSort(.name)) { node in
        HStack(spacing: 4) {
          if node.isGroup && !node.childNodes.isEmpty {
            Button {
              selection = expansion.setExpanded(
                expansion.isCollapsed(node.id), for: node, selection: selection)
            } label: {
              Image(systemName: "chevron.right")
                .font(.caption2.weight(.semibold))
                .rotationEffect(.degrees(expansion.isCollapsed(node.id) ? 0 : 90))
                .frame(minWidth: 24, minHeight: 28)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expansion.isCollapsed(node.id) ? "展开" : "收起")
          } else {
            Color.clear.frame(width: 24, height: 28)
          }
          ServerTableNameCell(node: node, activeTargetID: activeTargetID)
        }
        .padding(.leading, CGFloat(depths[node.id] ?? 0) * 14)
      }
      .width(min: 160, ideal: 240)
      TableColumn("创建时间", sortUsing: ServerTableSort(.createdAt)) { node in
        timestampCell(node.createdAt)
      }
      .width(min: 100, ideal: timestampColumnWidth)
      TableColumn("修改时间", sortUsing: ServerTableSort(.updatedAt)) { node in
        timestampCell(node.updatedAt)
      }
      .width(min: 100, ideal: timestampColumnWidth)
    } rows: {
      ForEach(rows) { row in
        TableRow(row.node)
          .itemProvider {
            guard let payload = workflow.dragPayload(for: row.id) else { return nil }
            return dropState.provider(for: row.id, payload: payload)
          }
      }
    }
    .contextMenu(forSelectionType: NodeID.self) { ids in
      if let id = ids.first, let node = workflow.tree.node(withID: id) {
        ServerNodeContextMenu(
          node: node, workflow: workflow, activation: activation, errors: errors,
          onEdit: presentEditServer, onRename: { renameTarget = $0 },
          onNewGroup: presentNewGroup, onDuplicate: duplicateNode,
          onDelete: { deleteTarget = $0 }, onExport: exportConfigurationGroup)
      }
    }
    .onKeyPress(.escape) {
      guard selection != nil else { return .ignored }
      selection = nil
      return .handled
    }
    .overlay {
      if rows.isEmpty {
        ContentUnavailableView(
          "暂无服务器", systemImage: "server.rack",
          description: Text("用工具栏的「新建服务器」按钮手动录入，或用「导入」菜单导入")
        )
        .allowsHitTesting(false)
      }
    }
    .background { ServerTableDropReader(state: dropState) }
    .onDrop(
      of: [.serverCatalogNode],
      delegate: ServerTableDropDelegate(
        state: dropState, rows: rows, source: source, workflow: workflow, onDrop: handleDrop)
    )
    .toolbar { toolbarContent }
  }

  private func timestampCell(_ date: Date?) -> some View {
    Text(date.map { Self.timestampFormatter.string(from: $0) } ?? "—")
      .lineLimit(1)
      .foregroundStyle(.secondary)
  }

  private static let timestampFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateStyle = .short
    formatter.timeStyle = .short
    return formatter
  }()

  private var timestampColumnWidth: CGFloat {
    let text = Self.timestampFormatter.string(from: Date())
    return ceil(
      (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 13)]).width) + 24
  }

  /// 删除结果 → selection invalidation（story 18）：仅清除失效选择，不自动
  /// 改选相邻节点。
  private func clearSelectionIfInvalidated(_ removed: Set<NodeID>) {
    if let selection, removed.contains(selection) {
      self.selection = nil
    }
  }

  /// 落点语义：拖到分组行 = 移入该组（仅手动组接受），拖到列表空白/根 = 移到根。
  /// 资格事实由 seam 提供；跨来源/成环仍由领域拒绝（不变量防线）。
  private func handleDrop(_ payload: [String], onto target: NodeID?) -> Bool {
    guard payload.count == 1, let raw = payload.first else { return false }
    let dragged = NodeID(rawValue: raw)
    guard workflow.canMove(dragged, to: target) else { return false }
    Task {
      do {
        try await workflow.move(dragged, to: target)
        selectCreatedNode(dragged)
      } catch {
        errors.present(error)
      }
    }
    return true
  }

  private func exportConfigurationGroup(_ id: NodeID) {
    switch ConfigurationGroupExportAction(
      workflow: workflow, exporter: configurationGroupFileExporter
    ).perform(for: id) {
    case .preparationFailed(let failure):
      errors.present(failure)
    case .cancelled, .saved:
      break
    case .exportFailed(let failure):
      errors.present(failure)
    }
  }
}

extension ServersView {
  // MARK: - 详情区

  @ViewBuilder
  private var serverDetailPane: some View {
    if let id = selection, let node = workflow.tree.node(withID: id) {
      if node.isGroup {
        GroupDetailView(
          workflow: workflow, groupID: id,
          activation: activation,
          errors: errors)
      } else {
        ServerDetailView(
          workflow: workflow, serverID: id, isActiveTarget: activeTargetID == id
        )
        .id(id)
      }
    } else {
      ContentUnavailableView(
        "未选择节点", systemImage: "sidebar.left",
        description: Text("在左侧选择服务器或分组查看详情"))
    }
  }

  // MARK: - 工具栏（新建服务器 / 新建分组 / 分享）

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Picker(
          "排序",
          selection: Binding<ServerTableSort.Field?>(
            get: { sortOrder.first?.field },
            set: { field in sortOrder = field.map { [ServerTableSort($0)] } ?? [] })
        ) {
          Text("无").tag(nil as ServerTableSort.Field?)
          Text("名称").tag(ServerTableSort.Field.name as ServerTableSort.Field?)
          Text("创建时间").tag(ServerTableSort.Field.createdAt as ServerTableSort.Field?)
          Text("修改时间").tag(ServerTableSort.Field.updatedAt as ServerTableSort.Field?)
        }
        .pickerStyle(.inline)
      } label: {
        Label("排序", systemImage: "arrow.up.arrow.down")
      }
      .labelStyle(.iconOnly)
      .help("排序")
    }
    ToolbarItem(placement: .primaryAction) {
      Button {
        presentNewServer(in: workflow.importTargetParent(for: selection))
      } label: {
        Label("新建服务器", systemImage: "plus")
      }
      .help("新建服务器")
    }
    ToolbarItem(placement: .primaryAction) {
      Button {
        presentNewGroup(in: workflow.importTargetParent(for: selection))
      } label: {
        Label("新建分组", systemImage: "folder.badge.plus")
      }
      .help("新建分组")
    }
    ToolbarItem(placement: .primaryAction) {
      Button {
        if let selection { presentEditServer(selection) }
      } label: {
        Label("编辑服务器", systemImage: "pencil")
      }
      .labelStyle(.iconOnly)
      .help("编辑服务器")
      .disabled(selection.flatMap { workflow.serverFormPresentation(for: $0) }?.isEditable != true)
    }
    ToolbarItem(placement: .primaryAction) {
      Button {
        if let selection { duplicateNode(selection) }
      } label: {
        Label("复制", systemImage: "plus.square.on.square")
      }
      .help("复制")
      .disabled(selection.map(workflow.canDuplicate) != true)
    }
    // 删除：作用于当前选中的服务器叶子或手动分组，确认弹窗与右键菜单共用
    // deleteTarget 流（档位见 deleteFacts）；无选中或选中项不可删（订阅节点
    // 结构只读，GLOSSARY.md）即禁用，资格判定归政策 seam。
    ToolbarItem(placement: .primaryAction) {
      Button {
        deleteTarget = selection
      } label: {
        Label("删除", systemImage: "trash")
      }
      .help("删除")
      .disabled(!canDeleteSelection)
    }
    // 分享选中的服务器或非空配置组，分别显示二维码或文件/URI 列表操作。
    ToolbarItem(placement: .primaryAction) {
      Button {
        presentShare()
      } label: {
        Label("分享", systemImage: "square.and.arrow.up")
      }
      .help("分享")
      .disabled(!canShareSelection)
      .popover(item: $shareContext, arrowEdge: .top) { context in
        switch context {
        case .server(let server):
          ShareServerPopover(
            payload: server.payload,
            presentation: server.presentation,
            suggestedFileName: server.suggestedFileName,
            imageClipboard: imageClipboard,
            textClipboard: clipboard,
            saver: qrImageSaver,
            errors: errors)
        case .group(let group):
          ShareGroupPopover(
            context: group, exporter: configurationGroupFileExporter,
            clipboard: clipboard, errors: errors)
        }
      }
    }
  }

  // MARK: - 告警动作

  /// 工具栏删除钮可用性：无选中或选中项不可删（订阅节点、失效选择）即禁用。
  private var canDeleteSelection: Bool {
    selection.map(workflow.canDelete) ?? false
  }

  private func presentNewGroup(in parent: NodeID?) {
    newGroupParent = parent
    isPresentingNewGroup = true
  }

  private func presentNewServer(in parent: NodeID?) {
    serverFormOperation = .create(parent: parent)
  }

  private func presentEditServer(_ id: NodeID) {
    guard workflow.serverFormPresentation(for: id)?.isEditable == true else { return }
    serverFormOperation = .edit(id)
  }

  private func selectCreatedNode(_ id: NodeID) {
    source = .manual
    expansion.reveal(id, in: workflow.tree)
    selection = id
  }

  private func duplicateNode(_ id: NodeID) {
    Task {
      do {
        let copy = try await workflow.duplicate(id, nameSuffix: String(localized: "副本"))
        selectCreatedNode(copy)
      } catch {
        errors.present(error)
      }
    }
  }

  /// 删除确认文案：档位与规模事实来自 seam；句子由 UI 拼（Q3-A）。
  private var deleteTitle: String {
    guard let id = deleteTarget else { return "" }
    let name = workflow.displayName(for: id)
    switch workflow.deleteFacts(for: id) {
    case .subtree:
      return "删除分组「\(name)」及其整棵子树？"
    case .leaf, .emptyGroup, nil:
      return "删除「\(name)」？"
    }
  }

  private var deleteMessage: String {
    guard let id = deleteTarget else { return "" }
    switch workflow.deleteFacts(for: id) {
    case .subtree(let count, let includesCredentials):
      if includesCredentials {
        return "将递归删除 \(count) 个节点（含其中的服务器与凭据），此操作不可撤销。"
      }
      return "将递归删除 \(count) 个节点，此操作不可撤销。"
    case .leaf, .emptyGroup, nil:
      return "此操作不可撤销。"
    }
  }

  private func commitDelete() {
    guard let id = deleteTarget else { return }
    deleteTarget = nil
    Task {
      do {
        let outcome = try await workflow.remove(id)
        clearSelectionIfInvalidated(outcome.removedNodeIDs)
      } catch {
        errors.present(error)
      }
    }
  }
}

/// renameTarget 的 sheet(item:) 适配壳。
private struct NodeContext: Identifiable {
  let nodeID: NodeID
  var id: NodeID { nodeID }
}
