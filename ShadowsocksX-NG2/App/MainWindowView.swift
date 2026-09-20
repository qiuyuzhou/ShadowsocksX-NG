import SwiftUI

/// 主窗口（spec #21 D11，issue #32/#34）：NavigationSplitView 分区。侧栏顶部
/// 分区切换「服务器 / 诊断」；服务器分区是配置目录分组树（订阅子树只读、仅
/// 启用开关）与详情编辑；诊断分区是日志查看与脱敏导出（D11「诊断收进主窗
/// 口」）。所有编辑类操作只在主窗口。
struct MainWindowView: View {
  enum Pane: Hashable {
    case servers
    case diagnostics
  }

  @ObservedObject var viewModel: CatalogViewModel
  @ObservedObject var proxyController: ProxyRuntimeController
  let eventStore: RuntimeEventStore

  @State private var pane: Pane = .servers
  @State private var renameTarget: NodeID?
  @State private var renameText = ""
  @State private var newGroupParent: NodeID?
  @State private var newGroupName = ""
  @State private var deleteTarget: NodeID?
  @State private var moveTarget: NodeID?
  @State private var showImportURLSheet = false
  @State private var showQRImportSheet = false
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
        get: { viewModel.presentedError != nil },
        set: { if !$0 { viewModel.presentedError = nil } })
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(viewModel.presentedError ?? "")
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
      ImportURLSheet(viewModel: viewModel)
    }
    .sheet(isPresented: $showQRImportSheet) {
      QRImportSheet(viewModel: viewModel)
    }
    .sheet(
      item: Binding(
        get: { moveTarget.map(MoveContext.init) },
        set: { moveTarget = $0?.nodeID })
    ) { context in
      MoveNodeSheet(viewModel: viewModel, nodeID: context.nodeID)
    }
  }

  // MARK: - 侧栏（分区切换 + 树 / 诊断摘要）

  private var sidebar: some View {
    VStack(spacing: 0) {
      Picker("分区", selection: $pane) {
        Text("服务器").tag(Pane.servers)
        Text("诊断").tag(Pane.diagnostics)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
      .padding(.horizontal, 8)
      .padding(.vertical, 6)
      if pane == .servers {
        serverSidebar
      } else {
        diagnosticsSidebar
      }
    }
  }

  /// 诊断分区侧栏：代理状态摘要与脱敏说明（详情与导出入口在右侧日志区）。
  private var diagnosticsSidebar: some View {
    DiagnosticsSummarySidebar(proxyController: proxyController)
  }

  private var serverSidebar: some View {
    List(selection: $viewModel.selectedNodeID) {
      OutlineGroup(viewModel.sidebarNodes(), children: \.children) { node in
        SidebarRow(
          node: node,
          viewModel: viewModel,
          proxyController: proxyController,
          onRename: { id in
            renameTarget = id
            renameText = viewModel.displayName(for: id)
          },
          onNewGroup: { parent in
            newGroupParent = parent
            newGroupName = ""
          },
          onMove: { moveTarget = $0 },
          onDelete: { deleteTarget = $0 }
        )
        .onDrag {
          // 订阅节点结构只读：携带空负载，落点校验节点存在性后自动忽略。
          node.source == .manual
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
      if viewModel.catalog.isEmpty {
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

  /// 落点语义：拖到分组行 = 移入该组（仅手动组接受），拖到列表空白/根 = 移到根。
  /// 跨来源由视图过滤 + 领域拒绝双重保证；无效负载不接收。
  private func handleDrop(_ payload: [String], onto target: NodeID?) -> Bool {
    guard let raw = payload.first else { return false }
    let dragged = NodeID(rawValue: raw)
    guard dragged != target, viewModel.catalog.contains(dragged) else { return false }
    Task {
      do {
        try await viewModel.move(dragged, to: target)
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
    return true
  }

  // MARK: - 详情区

  @ViewBuilder
  private var detailPane: some View {
    if pane == .diagnostics {
      DiagnosticsView(
        viewModel: viewModel, proxyController: proxyController, eventStore: eventStore)
    } else if let id = viewModel.selectedNodeID, let entry = viewModel.entry(for: id) {
      switch entry.kind {
      case .server:
        ServerDetailView(
          viewModel: viewModel, serverID: id, proxyController: proxyController)
      case .group:
        GroupDetailView(viewModel: viewModel, groupID: id, proxyController: proxyController)
      }
    } else {
      ContentUnavailableView(
        "未选择节点", systemImage: "sidebar.left",
        description: Text("在左侧选择服务器或分组查看与编辑详情"))
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
        Divider()
        Button("新建分组…") {
          newGroupParent = viewModel.importTargetParent(for: viewModel.selectedNodeID)
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
        let parent = viewModel.importTargetParent(for: viewModel.selectedNodeID)
        let outcome = try await viewModel.addServers(fromURIs: text, into: parent)
        if outcome.added == 0 && outcome.failures.isEmpty {
          viewModel.presentedError = "剪贴板没有可导入的文本"
        } else if !outcome.failures.isEmpty {
          viewModel.presentedError =
            "已添加 \(outcome.added) 台服务器；以下条目无法解析：\n"
            + outcome.failures.joined(separator: "\n")
        }
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }

  // MARK: - 告警动作

  private func commitRename() {
    guard let id = renameTarget else { return }
    renameTarget = nil
    Task {
      do {
        try await viewModel.renameGroup(id, to: renameText)
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }

  private func commitNewGroup() {
    guard let parent = newGroupParent else { return }
    newGroupParent = nil
    Task {
      do {
        _ = try await viewModel.addGroup(named: newGroupName, into: parent)
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }

  private var deleteTargetName: String {
    deleteTarget.map { viewModel.displayName(for: $0) } ?? ""
  }

  /// 删除语义：非空手动组点名子树规模（二次确认），空组与服务器单次确认。
  private var deleteTitle: String {
    guard let id = deleteTarget,
      let entry = viewModel.entry(for: id),
      case .group = entry.kind,
      entry.source == .manual
    else { return "删除「\(deleteTargetName)」？" }
    return "删除分组「\(deleteTargetName)」及其整棵子树？"
  }

  private var deleteMessage: String {
    guard let id = deleteTarget, let entry = viewModel.entry(for: id),
      case .group(let fields) = entry.kind, entry.source == .manual
    else { return "此操作不可撤销。" }
    let count = subtreeCount(fields.children)
    return "将递归删除 \(count) 个节点（含其中的服务器与凭据），此操作不可撤销。"
  }

  private func subtreeCount(_ children: [NodeID]) -> Int {
    children.reduce(0) { total, child in
      let grandchildren = (try? viewModel.catalog.children(of: child)) ?? []
      return total + 1 + subtreeCount(grandchildren)
    }
  }

  private func commitDelete() {
    guard let id = deleteTarget else { return }
    deleteTarget = nil
    Task {
      do {
        try await viewModel.remove(id)
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }
}

/// moveTarget 的 sheet(item:) 适配壳。
private struct MoveContext: Identifiable {
  let nodeID: NodeID
  var id: NodeID { nodeID }
}
