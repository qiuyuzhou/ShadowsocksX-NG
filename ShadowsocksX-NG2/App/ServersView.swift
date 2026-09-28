import SwiftUI

/// 服务器 destination（spec #21 D11，issue #32/#34/#35/#41）：承载服务器目录树、
/// 详情编辑与分组命令。workspace destination 由外层主窗口壳持有（新壳在
/// MainWindowView.swift，票 #53）；全局导入表单由窗口壳呈现，本视图持有服务器
/// 功能的 sheet、alert、确认弹窗与编辑草稿边界；selection 由外层绑定，以便订阅
/// 删除仍能清除失效的服务器选择。
struct ServersView: View {

  @ObservedObject var workflow: CatalogWorkflow
  /// 运行时事实来源：活动目标标记；激活命令经 `workflow.activate`。
  @ObservedObject var proxyController: ProxyRuntimeController
  @Binding var selection: NodeID?
  let clipboard: any TextClipboard

  /// 共享错误弹窗呈现（UI 持有；typed error → 本地化文案的呈现边缘）。
  @StateObject private var errors = ErrorAlertPresenter()

  // 纯窗口状态（issue #41）：selection/sheet/alert 不进目录 module。
  @State private var renameTarget: NodeID?
  @State private var renameText = ""
  @State private var newGroupParent: NodeID?
  @State private var newGroupName = ""
  @State private var isPresentingNewGroup = false
  @State private var deleteTarget: NodeID?
  @State private var moveTarget: NodeID?
  @State private var rootDropHovering = false

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
    .alert(
      "新建分组",
      isPresented: $isPresentingNewGroup
    ) {
      TextField("名称", text: $newGroupName)
      Button("创建") { commitNewGroup() }
      Button("取消", role: .cancel) { cancelNewGroup() }
    }
    .alert(
      "操作失败",
      isPresented: Binding(
        get: { errors.isPresented },
        set: { if !$0 { errors.dismiss() } })
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(errors.message ?? "")
    }
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
  }

  private var serverSidebar: some View {
    List(selection: $selection) {
      OutlineGroup(workflow.tree.roots, children: \.children) { node in
        SidebarRow(
          node: node,
          workflow: workflow,
          activeTargetID: proxyController.activeTargetID,
          errors: errors,
          onRename: { id in
            renameTarget = id
            renameText = workflow.displayName(for: id)
          },
          onNewGroup: { parent in
            presentNewGroup(in: parent)
          },
          onMove: { moveTarget = $0 },
          onDelete: { deleteTarget = $0 }
        )
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
    }
    .listStyle(.sidebar)
    .overlay(alignment: .center) {
      if workflow.tree.isEmpty {
        ContentUnavailableView(
          "暂无服务器", systemImage: "server.rack",
          description: Text("用工具栏的「添加」菜单导入 ss:// 链接，或用「新建分组」按钮创建分组")
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
}

extension ServersView {
  // MARK: - 详情区

  @ViewBuilder
  private var serverDetailPane: some View {
    if let id = selection, let node = workflow.tree.node(withID: id) {
      if node.isGroup {
        GroupDetailView(
          workflow: workflow, groupID: id,
          errors: errors)
      } else {
        ServerDetailView(
          workflow: workflow, serverID: id, isActiveTarget: proxyController.activeTargetID == id,
          errors: errors, clipboard: clipboard)
      }
    } else {
      ContentUnavailableView(
        "未选择节点", systemImage: "sidebar.left",
        description: Text("在左侧选择服务器或分组查看与编辑详情"))
    }
  }

  // MARK: - 工具栏（新建分组）

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Button {
        presentNewGroup(in: workflow.importTargetParent(for: selection))
      } label: {
        Label("新建分组", systemImage: "folder.badge.plus")
      }
      .labelStyle(.iconOnly)
      .help("新建分组")
    }
  }

  // MARK: - 告警动作

  private func presentNewGroup(in parent: NodeID?) {
    newGroupParent = parent
    newGroupName = ""
    isPresentingNewGroup = true
  }

  private func cancelNewGroup() {
    isPresentingNewGroup = false
    newGroupParent = nil
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

  private func commitNewGroup() {
    let parent = newGroupParent
    let name = newGroupName
    cancelNewGroup()
    Task {
      do {
        _ = try await workflow.createGroup(named: name, into: parent)
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
