import SwiftUI

/// 主窗口（spec #21 D11，issue #32/#34/#35/#41）：NavigationSplitView 分区。
/// 侧栏顶部分区切换「服务器 / 订阅 / 诊断」；服务器分区是配置目录分组树（订阅
/// 子树只读）与详情编辑；订阅分区是订阅卡片与刷新/编辑/删除；诊断
/// 分区是日志查看与脱敏导出（D11「诊断收进主窗口」）。编辑类操作只在主窗口
/// （菜单栏仅保留 D11 白名单内的「立即更新全部订阅」快速动作）。
/// 窗口状态（选择、pane、sheet、alert、确认弹窗）由本视图持有；目录事实与
/// 命令结果全部经由目录工作流 module（issue #41）。
struct MainWindowView: View {
  enum Pane: Hashable {
    case servers
    case subscriptions
    case diagnostics
  }

  @ObservedObject var workflow: CatalogWorkflow
  @ObservedObject var proxyController: ProxyRuntimeController
  let eventStore: RuntimeEventStore

  /// 共享错误弹窗呈现（UI 持有；typed error → 本地化文案的呈现边缘）。
  @StateObject private var errors = ErrorAlertPresenter()

  // 纯窗口状态（issue #41）：selection/pane/sheet/alert 不进目录 module。
  @State private var pane: Pane = .servers
  @State private var selection: NodeID?
  @State private var renameTarget: NodeID?
  @State private var renameText = ""
  @State private var newGroupParent: NodeID?
  @State private var newGroupName = ""
  @State private var deleteTarget: NodeID?
  @State private var moveTarget: NodeID?
  @State private var showImportURLSheet = false
  @State private var showQRImportSheet = false
  @State private var showLegacyImportSheet = false
  @State private var didOfferLegacyImport = false
  @State private var rootDropHovering = false

  var body: some View {
    NavigationSplitView {
      sidebar
    } detail: {
      detailPane
    }
    .frame(minWidth: 720, minHeight: 420)
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
      isPresented: Binding(
        get: { newGroupParent != nil },
        set: { if !$0 { newGroupParent = nil } })
    ) {
      TextField("名称", text: $newGroupName)
      Button("创建") { commitNewGroup() }
      Button("取消", role: .cancel) { newGroupParent = nil }
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
    .sheet(isPresented: $showImportURLSheet) {
      ImportURLSheet(workflow: workflow, errors: errors, selection: $selection)
    }
    .sheet(isPresented: $showQRImportSheet) {
      QRImportSheet(workflow: workflow, errors: errors, selection: $selection)
    }
    .sheet(isPresented: $showLegacyImportSheet) {
      LegacyImportSheet(workflow: workflow)
    }
    .sheet(
      item: Binding(
        get: { moveTarget.map(MoveContext.init) },
        set: { moveTarget = $0?.nodeID })
    ) { context in
      MoveNodeSheet(workflow: workflow, errors: errors, nodeID: context.nodeID)
    }
    .onAppear {
      guard !didOfferLegacyImport, workflow.legacyImportState.shouldOffer else { return }
      didOfferLegacyImport = true
      showLegacyImportSheet = true
    }
  }

  // MARK: - 侧栏（分区切换 + 树 / 诊断摘要）

  private var sidebar: some View {
    VStack(spacing: 0) {
      Picker("分区", selection: $pane) {
        Text("服务器").tag(Pane.servers)
        Text("订阅").tag(Pane.subscriptions)
        Text("诊断").tag(Pane.diagnostics)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      switch pane {
      case .servers:
        serverSidebar
      case .subscriptions:
        subscriptionsSidebar
      case .diagnostics:
        diagnosticsSidebar
      }
    }
  }

  /// 诊断分区侧栏：代理状态摘要与脱敏说明（详情与导出入口在右侧日志区）。
  private var diagnosticsSidebar: some View {
    DiagnosticsSummarySidebar(proxyController: proxyController)
  }

  /// 订阅分区侧栏：订阅摘要说明（卡片与操作全在右侧详情区）。
  private var subscriptionsSidebar: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text("订阅")
        .font(.headline)
      Text("每个订阅是一张卡片：远端 SIP-008 文档经解析校验后原子提交；刷新失败保留最后一次成功内容。远端名称、结构与成员权威；不支持的服务器配置会保留并在激活时跳过。")
        .font(.callout)
        .foregroundStyle(.secondary)
      Spacer()
    }
    .padding(12)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var serverSidebar: some View {
    List(selection: $selection) {
      OutlineGroup(workflow.tree.roots, children: \.children) { node in
        SidebarRow(
          node: node,
          workflow: workflow,
          proxyController: proxyController,
          errors: errors,
          onRename: { id in
            renameTarget = id
            renameText = workflow.displayName(for: id)
          },
          onNewGroup: { parent in
            newGroupParent = parent
            newGroupName = ""
          },
          onMove: { moveTarget = $0 },
          onDelete: { deleteTarget = $0 },
          onRemoved: { clearSelectionIfInvalidated($0) }
        )
        .onDrag {
          // 订阅节点结构只读：携带空负载，落点校验节点存在性后自动忽略。
          node.isManual
            ? NSItemProvider(object: node.id.rawValue as NSString)
            : NSItemProvider()
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
          description: Text("用工具栏「添加」导入 ss:// 链接或新建分组")
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
  /// 跨来源由视图过滤 + 领域拒绝双重保证；无效负载不接收。
  private func handleDrop(_ payload: [String], onto target: NodeID?) -> Bool {
    guard let raw = payload.first else { return false }
    let dragged = NodeID(rawValue: raw)
    guard dragged != target, workflow.tree.containsNode(dragged) else { return false }
    Task {
      do {
        try await workflow.move(dragged, to: target)
      } catch {
        errors.present(error)
      }
    }
    return true
  }

  // MARK: - 详情区

  @ViewBuilder
  private var detailPane: some View {
    switch pane {
    case .diagnostics:
      DiagnosticsView(
        workflow: workflow, proxyController: proxyController, eventStore: eventStore,
        errors: errors)
    case .subscriptions:
      SubscriptionsView(
        workflow: workflow, errors: errors,
        onNodesRemoved: { clearSelectionIfInvalidated($0) })
    case .servers:
      if let id = selection, let node = workflow.tree.node(withID: id) {
        if node.isGroup {
          GroupDetailView(
            workflow: workflow, groupID: id, proxyController: proxyController,
            errors: errors)
        } else {
          ServerDetailView(
            workflow: workflow, serverID: id, proxyController: proxyController,
            errors: errors)
        }
      } else {
        ContentUnavailableView(
          "未选择节点", systemImage: "sidebar.left",
          description: Text("在左侧选择服务器或分组查看与编辑详情"))
      }
    }
  }

  // MARK: - 工具栏（添加三入口 + 新建分组）

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItem(placement: .primaryAction) {
      Menu {
        Button("从剪贴板导入 ss://") { importFromClipboard() }
        Button("通过 URL 导入…") { showImportURLSheet = true }
        Button("从二维码图片导入…") { showQRImportSheet = true }
        if workflow.legacyImportState.snapshotFound {
          Divider()
          Button(
            workflow.legacyImportState.completed ? "再次导入 Legacy 配置…" : "导入 Legacy 配置…"
          ) {
            showLegacyImportSheet = true
          }
        }
        Divider()
        Button("新建分组…") {
          newGroupParent = workflow.importTargetParent(for: selection)
          newGroupName = ""
        }
      } label: {
        Label("添加", systemImage: "plus")
      }
    }
  }

  /// 剪贴板入口：整段剪贴板文本按行解析导入当前落点。
  private func importFromClipboard() {
    let text = NSPasteboard.general.string(forType: .string) ?? ""
    performImport(text)
  }

  private func performImport(_ text: String) {
    Task {
      do {
        let parent = workflow.importTargetParent(for: selection)
        let outcome = try await workflow.createServers(fromURIs: text, into: parent)
        if outcome.addedCount == 0 && outcome.failures.isEmpty {
          errors.present(text: "剪贴板没有可导入的文本")
        } else if let message = ImportOutcomePresentation.failureMessage(outcome) {
          errors.present(text: message)
        }
      } catch {
        errors.present(error)
      }
    }
  }

  // MARK: - 告警动作

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
    guard let parent = newGroupParent else { return }
    newGroupParent = nil
    Task {
      do {
        _ = try await workflow.createGroup(named: newGroupName, into: parent)
      } catch {
        errors.present(error)
      }
    }
  }

  private var deleteTargetNode: CatalogTreeNode? {
    deleteTarget.flatMap { workflow.tree.node(withID: $0) }
  }

  /// 删除语义：非空手动组点名子树规模（二次确认），空组与服务器单次确认。
  private var deleteTitle: String {
    guard let node = deleteTargetNode, node.isGroup, node.isManual else {
      return "删除「\(deleteTargetName)」？"
    }
    return "删除分组「\(deleteTargetName)」及其整棵子树？"
  }

  private var deleteMessage: String {
    guard let node = deleteTargetNode, node.isGroup, node.isManual else {
      return "此操作不可撤销。"
    }
    return "将递归删除 \(node.subtreeNodeCount) 个节点（含其中的服务器与凭据），此操作不可撤销。"
  }

  private var deleteTargetName: String {
    deleteTarget.map { workflow.displayName(for: $0) } ?? ""
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
