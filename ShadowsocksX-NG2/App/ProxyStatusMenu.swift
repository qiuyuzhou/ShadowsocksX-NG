import AppKit
import SwiftUI

/// 状态菜单（spec #21 D11 八项白名单，issue #31/#41/#47）：①头部状态摘要
/// （运行状态、当前模式、活动目标）②代理开关 ③模式选择（勾选态）④活动目标
/// 级联选择器（组树子菜单、只读）⑤立即更新全部订阅 ⑥复制 HTTP 导出行 ⑦打开
/// 主窗口 ⑧打开设置 ⑨退出（明示代理仍在后台运行）。白名单外操作一律不进菜单
/// 栏；编辑类操作只在主 workspace。运行时事实、开关、模式与导出能力全部
/// 来自代理控制工作流的整体 snapshot（issue #47），菜单不直接读控制器字段；
/// 目录树、激活与订阅动作仍走目录工作流，剪贴板写入等 AppKit 副作用留在呈现
/// 边界。
struct ProxyStatusMenu: View {
  @Environment(\.openWindow) private var openWindow
  /// 代理控制唯一 seam（issue #47）：状态摘要与代理命令的唯一来源。
  @ObservedObject var control: ProxyControlWorkflow
  @ObservedObject var catalogWorkflow: CatalogWorkflow
  @ObservedObject var route: WorkspaceRoute
  let clipboard: any TextClipboard
  @StateObject private var errors = ErrorAlertPresenter()

  var body: some View {
    menuContent
      .task {
        guard !isUnitTesting else { return }
        await control.resyncOnLaunch()
        route.handle(
          .launch(legacyImportOffer: catalogWorkflow.legacyImportState.shouldOffer),
          using: WorkspaceWindowOpeningAdapter(openWindow: openWindow))
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
  }

  @ViewBuilder
  private var menuContent: some View {
    let snapshot = control.snapshot
    let summary = StatusMenuModel.summary(from: snapshot)
    let targetTree = catalogWorkflow.tree.roots
    let exportLine = snapshot.httpExport?.copyableLine

    // ① 头部状态摘要
    Text(summary.status)
    Text("模式：\(summary.modeLabel)")
    Text(summary.targetPath.map { "目标：\($0)" } ?? "目标：未激活")
    if let detail = summary.detail {
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    if snapshot.skippedInvalidServerCount > 0 {
      Text("已跳过 \(snapshot.skippedInvalidServerCount) 个无效服务器")
        .font(.caption)
        .foregroundStyle(.orange)
        .help("激活时跳过了存在已知本地阻塞问题的服务器")
    }

    Divider()

    // ② 代理开关
    Button(summary.isOn ? "停止代理" : "启动代理") {
      Task { await control.setProxyEnabled(!summary.isOn) }
    }

    // ③ 模式选择（勾选态）：可选性与顺序来自 snapshot 的 Domain 单点策略。
    Picker("模式", selection: modeBinding) {
      ForEach(snapshot.availableModes, id: \.self) { mode in
        Text(mode.label).tag(mode)
      }
    }
    .pickerStyle(.inline)

    // ④ 活动目标级联（只读）
    Menu("活动目标") {
      if targetTree.isEmpty {
        Text("目录为空")
      } else {
        TargetCascade(nodes: targetTree, activeTargetID: snapshot.activeTarget?.id)
      }
    }

    Divider()

    // ⑤ 立即更新全部订阅（实际刷新语义 #35）
    Button("立即更新全部订阅") {
      Task { await catalogWorkflow.refreshAllSubscriptions() }
    }
    .disabled(catalogWorkflow.subscriptions.isEmpty)

    // ⑥ 复制 HTTP 导出行：workflow 只提供安全能力，复制是 UI 副作用。
    Button("复制 HTTP 导出行") {
      if let exportLine {
        copyHTTPExportLine(exportLine)
      }
    }
    .disabled(exportLine == nil)

    Divider()

    // ⑦ 打开主窗口
    Button("打开主窗口…") {
      route.handle(
        .reopen,
        using: WorkspaceWindowOpeningAdapter(openWindow: openWindow))
    }

    // 通过同一 workspace route 选择设置，再由 focused adapter 确保主窗口可见。
    Button("打开设置…") {
      route.handle(
        .present(destination: .settings),
        using: WorkspaceWindowOpeningAdapter(openWindow: openWindow))
    }

    Divider()

    // ⑨ 退出：仅退 GUI；agent 由 launchd 持有，代理不受影响（构造上成立）。
    Button("退出 ShadowsocksX-NG 2.0（代理仍在后台运行）") {
      NSApp.terminate(nil)
    }
  }

  private var isUnitTesting: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestSessionIdentifier"] != nil
  }

  private func copyHTTPExportLine(_ line: String) {
    do {
      try clipboard.write(line)
    } catch {
      errors.present(error)
    }
  }

  /// 模式选择走同一控制 seam：切换语义与菜单勾选态由同一 snapshot 事实来源
  /// 保证一致（issue #47）。
  private var modeBinding: Binding<ProxyMode> {
    Binding(
      get: { control.snapshot.proxyMode },
      set: { mode in Task { await control.setProxyMode(mode) } })
  }

  /// 只读级联树：分组展开为子菜单，活动目标以勾选呈现；无编辑入口。
  /// 递归经由具名 View 类型展开（opaque 自引用无法编译）。
  private struct TargetCascade: View {
    let nodes: [CatalogTreeNode]
    let activeTargetID: NodeID?

    var body: some View {
      ForEach(nodes, id: \.id) { node in
        if node.isGroup {
          Menu(node.name) {
            if node.childNodes.isEmpty {
              Text("空分组")
            } else {
              TargetCascade(nodes: node.childNodes, activeTargetID: activeTargetID)
            }
          }
        } else if node.id == activeTargetID {
          Text("✓ \(node.name)")
        } else {
          Text(node.name)
        }
      }
    }
  }
}
