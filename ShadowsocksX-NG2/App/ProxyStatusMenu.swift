import AppKit
import SwiftUI

/// 状态菜单（spec #21 D11 八项白名单，issue #31）：①头部状态摘要（运行状态、
/// 当前模式、活动目标）②代理开关 ③模式选择（勾选态）④活动目标级联选择器
/// （组树子菜单、只读）⑤立即更新全部订阅 ⑥复制 HTTP 导出行 ⑦打开主窗口
/// ⑧打开设置 ⑨退出（明示代理仍在后台运行）。白名单外操作一律不进菜单栏；
/// 编辑类操作只在主窗口或设置窗口。
struct ProxyStatusMenu: View {
  @Environment(\.openWindow) private var openWindow
  @ObservedObject var controller: ProxyRuntimeController
  @ObservedObject var catalogViewModel: CatalogViewModel

  var body: some View {
    let summary = presentation
    let targetTree = StatusMenuModel.targetTree(
      catalog: catalogViewModel.catalog, activeTargetID: controller.activeTargetID)
    let exportLine = StatusMenuModel.httpExportLine(settings: controller.listenSettings)

    // ① 头部状态摘要
    Text(summary.status)
    Text("模式：\(summary.modeLabel)")
    Text(summary.targetPath.map { "目标：\($0)" } ?? "目标：未激活")
    if let detail = summary.detail {
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    Divider()

    // ② 代理开关
    Button(summary.isOn ? "停止代理" : "启动代理") {
      Task { await controller.setProxyEnabled(!summary.isOn) }
    }

    // ③ 模式选择（勾选态）
    Picker("模式", selection: modeBinding) {
      if isModeAvailable(.pac) {
        Text(ProxyMode.pac.label).tag(ProxyMode.pac)
      }
      if isModeAvailable(.global) {
        Text(ProxyMode.global.label).tag(ProxyMode.global)
      }
      if isModeAvailable(.manual) {
        Text(ProxyMode.manual.label).tag(ProxyMode.manual)
      }
      if let externalMode = configuredExternalPACMode {
        Text(externalMode.label).tag(externalMode)
      }
    }
    .pickerStyle(.inline)

    // ④ 活动目标级联（只读）
    Menu("活动目标") {
      if targetTree.isEmpty {
        Text("目录为空")
      } else {
        TargetCascade(nodes: targetTree)
      }
    }

    Divider()

    // ⑤ 立即更新全部订阅（实际刷新语义 #35）
    Button("立即更新全部订阅") {
      Task { await catalogViewModel.refreshAllSubscriptions() }
    }
    .disabled(catalogViewModel.subscriptions.isEmpty)

    // ⑥ 复制 HTTP 导出行
    Button("复制 HTTP 导出行") {
      if let exportLine {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(exportLine, forType: .string)
      }
    }
    .disabled(exportLine == nil)

    Divider()

    // ⑦ 打开主窗口
    Button("打开主窗口…") {
      NSApp.activate()
      openWindow(id: "main")
    }

    // 菜单栏 app 没有常规应用菜单；设置 scene 由这里显式打开。
    Button("打开设置…") {
      NSApp.activate()
      openWindow(id: "settings")
    }

    Divider()

    // ⑨ 退出：仅退 GUI；agent 由 launchd 持有，代理不受影响（构造上成立）。
    Button("退出 ShadowsocksX-NG 2.0（代理仍在后台运行）") {
      NSApp.terminate(nil)
    }
  }

  private var presentation: StatusMenuModel.Summary {
    StatusMenuModel.summary(
      state: controller.state,
      mode: controller.proxyMode,
      targetPath: StatusMenuModel.targetPath(
        catalog: catalogViewModel.catalog, activeTargetID: controller.activeTargetID))
  }

  /// 模式选择走控制器同一入口：切换的系统代理语义（#29）与菜单勾选态由
  /// 同一 @Published 事实来源保证一致。
  private var modeBinding: Binding<ProxyMode> {
    Binding(
      get: { controller.proxyMode },
      set: { mode in Task { await controller.setProxyMode(mode) } })
  }

  private func isModeAvailable(_ mode: ProxyMode) -> Bool {
    mode.kind == controller.proxyMode.kind || controller.settings.enabledModes.contains(mode.kind)
  }

  private var configuredExternalPACMode: ProxyMode? {
    if case .externalPAC(let url) = controller.proxyMode {
      return .externalPAC(url)
    }
    guard controller.settings.enabledModes.contains(.externalPAC),
      let url = URL(string: controller.settings.externalPACURL),
      !controller.settings.externalPACURL.isEmpty,
      (try? ProxyMode.validateExternalPACURL(url)) != nil
    else { return nil }
    return .externalPAC(url)
  }

  /// 只读级联树：分组展开为子菜单，活动目标以勾选呈现；无编辑入口。
  /// 递归经由具名 View 类型展开（opaque 自引用无法编译）。
  private struct TargetCascade: View {
    let nodes: [StatusMenuModel.TargetNode]

    var body: some View {
      ForEach(nodes, id: \.id) { node in
        if node.isGroup {
          Menu(node.name) {
            if node.children.isEmpty {
              Text("空分组")
            } else {
              TargetCascade(nodes: node.children)
            }
          }
        } else if node.isActive {
          Text("✓ \(node.name)")
        } else {
          Text(node.name)
        }
      }
    }
  }
}
