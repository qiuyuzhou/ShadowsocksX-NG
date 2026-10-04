import SwiftUI

/// 服务器 destination（spec #21 D11，issue #32/#34/#35/#41）：承载服务器目录树、
/// 详情编辑与分组命令。workspace destination 由外层主窗口壳持有（新壳在
/// MainWindowView.swift，票 #53）；全局导入表单由窗口壳呈现，本视图持有服务器
/// 功能的 sheet、alert、确认弹窗与编辑草稿边界；selection 由外层绑定，以便订阅
/// 删除仍能清除失效的服务器选择。
struct ServersView: View {

  @ObservedObject var workflow: CatalogWorkflow
  /// 激活反馈共享状态（三激活入口共用，单飞互斥）：侧栏右键与分组详情的
  /// 激活命令都经它发出。
  let activation: ActivationFeedbackState
  /// 活动目标标记：父视图传入的运行时事实，不进目录 projection（与
  /// SidebarRow/ServerDetailView 的传参先例同法）。
  let activeTargetID: NodeID?
  @Binding var selection: NodeID?
  /// 分组折叠状态：组合根持有的共享对象（与首页目标树同源），跨 destination
  /// 切换存续；OutlineGroup 的内建展开态会随分区切换丢失，侧栏因此自管折叠。
  @ObservedObject var expansion: CatalogExpansionState
  let clipboard: any TextClipboard
  let configurationGroupFileExporter: any ConfigurationGroupFileExporter

  /// 共享错误弹窗呈现（UI 持有；typed error → 本地化文案的呈现边缘）。
  /// 非 private：ServersView+Share.swift 扩展经它呈现分享失败。
  @StateObject var errors = ErrorAlertPresenter()

  // 纯窗口状态（issue #41）：selection/sheet/alert 不进目录 module。
  @State private var renameTarget: NodeID?
  @State private var renameText = ""
  @State private var newGroupParent: NodeID?
  @State private var newServerParent: NodeID?
  @State private var isPresentingNewGroup = false
  @State private var isPresentingNewServer = false
  @State private var deleteTarget: NodeID?
  @State private var moveTarget: NodeID?
  @State private var rootDropHovering = false
  @FocusState private var treeFocused: Bool
  // 分享/二维码状态：由 ServersView+Share.swift 扩展驱动，弹窗锚在工具栏
  // 分享按钮上（原详情区底部分享区已于 2026-10-04 上收至此）。
  @State var showQR = false
  @State var qrImage: NSImage?

  var body: some View {
    // 主窗口外壳（票 #53）已提供分栏框架；本分区用扁平双栏承载目录与详情
    // （票 #55 再按原型重排）。
    HStack(alignment: .top, spacing: 0) {
      serverSidebar
        .frame(minWidth: 240, idealWidth: 280, maxWidth: 340)
      Divider()
      serverDetailPane
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
    .frame(minHeight: 420)
    .alert(
      "重命名分组",
      isPresented: Binding(
        get: { renameTarget != nil },
        set: { if !$0 { renameTarget = nil } })
    ) {
      TextField("名称", text: $renameText)
      Button("确定") { commitRename() }
      Button("取消", role: .cancel) { renameTarget = nil }
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
    .sheet(
      item: Binding(
        get: { moveTarget.map(MoveContext.init) },
        set: { moveTarget = $0?.nodeID })
    ) { context in
      MoveNodeSheet(workflow: workflow, errors: errors, nodeID: context.nodeID)
    }
    .sheet(isPresented: $isPresentingNewServer) {
      NewServerSheet(
        workflow: workflow, errors: errors,
        parent: newServerParent, onCreated: selectCreatedNode)
    }
  }

  private var serverSidebar: some View {
    List(selection: $selection) {
      ForEach(workflow.tree.visibleRows(collapsed: expansion.collapsedGroupIDs)) { row in
        treeRow(row)
      }
    }
    .listStyle(.sidebar)
    .focusable(interactions: .edit)
    .focused($treeFocused)
    .onKeyPress(.escape) {
      guard treeFocused, selection != nil else { return .ignored }
      selection = nil
      return .handled
    }
    .background {
      ServerTreeBlankClickObserver {
        selection = nil
        treeFocused = true
      }
    }
    .overlay(alignment: .center) {
      if workflow.tree.isEmpty {
        ContentUnavailableView(
          "暂无服务器", systemImage: "server.rack",
          description: Text("用工具栏的「新建服务器」按钮手动录入，或用「导入」菜单导入 ss:// 链接")
        )
        .allowsHitTesting(false)
      }
    }
    .dropDestination(for: String.self) { payload, _ in
      handleDrop(payload, onto: nil)
    } isTargeted: { hovering in
      rootDropHovering = hovering
    }
    .toolbar { toolbarContent }
  }

  private func treeRow(_ row: CatalogTreeRow) -> some View {
    let node = row.node
    return HStack(spacing: 4) {
      if node.isGroup {
        if node.childNodes.isEmpty {
          Color.clear.frame(width: 11, height: 11)
        } else {
          Button {
            withAnimation { expansion.toggleCollapsed(node.id) }
          } label: {
            Image(systemName: "chevron.right")
              .font(.caption2.weight(.semibold))
              .foregroundStyle(.secondary)
              .rotationEffect(.degrees(expansion.isCollapsed(node.id) ? 0 : 90))
          }
          .buttonStyle(.plain)
          .help(expansion.isCollapsed(node.id) ? "展开" : "收起")
        }
      }
      SidebarRow(
        node: node,
        workflow: workflow,
        activation: activation,
        activeTargetID: activeTargetID,
        errors: errors,
        onRename: { id in
          renameTarget = id
          renameText = workflow.displayName(for: id)
        },
        onNewGroup: { parent in
          presentNewGroup(in: parent)
        },
        onMove: { moveTarget = $0 },
        onDelete: { deleteTarget = $0 },
        onExport: exportConfigurationGroup
      )
    }
    .padding(.leading, leadingInset(for: row))
    .tag(node.id)
    .onDrag {
      guard let payload = workflow.dragPayload(for: node.id) else {
        return NSItemProvider()
      }
      return NSItemProvider(object: payload as NSString)
    }
    .dropDestination(for: String.self) { payload, _ in
      handleDrop(payload, onto: node.id)
    } isTargeted: { _ in
    }
  }

  /// 层级缩进：分组行按深度缩进；叶子行额外让出箭头槽位与分组文本对齐。
  private func leadingInset(for row: CatalogTreeRow) -> CGFloat {
    let depthStep: CGFloat = 14
    let chevronSlot: CGFloat = 15
    if row.node.isGroup {
      return CGFloat(row.depth) * depthStep
    }
    return CGFloat(row.depth) * depthStep + chevronSlot
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
    guard let raw = payload.first else { return false }
    let dragged = NodeID(rawValue: raw)
    guard workflow.canMove(dragged, to: target) else { return false }
    Task {
      do {
        try await workflow.move(dragged, to: target)
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
          workflow: workflow, serverID: id, isActiveTarget: activeTargetID == id,
          errors: errors)
      }
    } else {
      ContentUnavailableView(
        "未选择节点", systemImage: "sidebar.left",
        description: Text("在左侧选择服务器或分组查看与编辑详情"))
    }
  }

  // MARK: - 工具栏（新建服务器 / 新建分组 / 分享）

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
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
    // 分享（分享/导出术语见 GLOSSARY.md）：作用于选中的服务器叶子，弹窗内
    // 提供二维码与复制 ss:// 链接两条通路；无有效载荷即不可用。
    ToolbarItem(placement: .primaryAction) {
      Button {
        generateQR()
      } label: {
        Label("分享", systemImage: "square.and.arrow.up")
      }
      .help("分享")
      .disabled(sharePayload() == nil)
      .popover(isPresented: $showQR) {
        qrPopover
      }
      // 弹窗开着时切换选中项：立即收起，避免内容滞留为旧服务器。
      .onChange(of: selection) {
        showQR = false
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
    newServerParent = parent
    isPresentingNewServer = true
  }

  private func selectCreatedNode(_ id: NodeID) {
    expansion.reveal(id, in: workflow.tree)
    selection = id
  }

  private func commitRename() {
    guard let id = renameTarget else { return }
    renameTarget = nil
    Task {
      do {
        try await workflow.renameGroup(id, to: renameText)
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

/// moveTarget 的 sheet(item:) 适配壳。
private struct MoveContext: Identifiable {
  let nodeID: NodeID
  var id: NodeID { nodeID }
}
