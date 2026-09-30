import AppKit
import SwiftUI

/// 状态菜单（spec #21 D11 白名单收敛为六项，issue #31/#41/#47/#60）：
/// ①打开主窗口（置顶单独区域）②头部状态摘要（agent 运行状态、当前模式、
/// 活动目标、系统代理实际应用）③两个开关（后台代理 agent 与系统代理，互不
/// 代替）④模式选择（勾选态）⑤活动目标级联选择器（组树子菜单、只读）
/// ⑥退出（明示代理仍在后台运行）。白名单外操作一律不进菜单栏；编辑类操作
/// 只在主 workspace。运行时事实、开关与模式全部来自代理控制工作流的整体
/// snapshot（issue #47/#60），菜单不直接读控制器字段；目录树与激活动作仍走
/// 目录工作流。
struct ProxyStatusMenu: View {
  /// 代理控制唯一 seam（issue #47）：状态摘要与代理命令的唯一来源。
  @ObservedObject var control: ProxyControlWorkflow
  @ObservedObject var catalogWorkflow: CatalogWorkflow
  /// 主窗口是 SwiftUI `Window` scene（见 MainApp）：启动呈现由场景的
  /// defaultLaunchBehavior 负责，状态菜单是关窗后的重开入口（ADR 0016）；
  /// scene id 经 WorkspaceRoute 单点引用。
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    let snapshot = control.snapshot
    let summary = StatusMenuModel.summary(from: snapshot)
    let targetTree = catalogWorkflow.tree.roots

    // ① 重开主窗口（置顶单独区域）：启动已由 defaultLaunchBehavior(.presented)
    // 呈现，本项服务关窗后的重开。accessory 形态下 SwiftUI 开窗不会自行抢
    // 焦点，先激活本 app 让窗口压过当前前台应用。
    Button("打开主窗口…") {
      NSApp.activate(ignoringOtherApps: true)
      openWindow(id: WorkspaceRoute.workspaceSceneID)
    }

    Divider()

    // ② 头部状态摘要（agent 运行状态与系统代理实际应用分开呈现，issue #60）
    Text(summary.status)
    Text("模式：\(summary.modeLabel)")
    Text(summary.targetPath.map { "目标：\($0)" } ?? "目标：未激活")
    if let detail = summary.detail {
      Text(detail)
        .font(.caption)
        .foregroundStyle(.secondary)
    }
    Text(summary.systemProxyStatus)
    if let systemProxyDetail = summary.systemProxyDetail {
      Text(systemProxyDetail)
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

    // ③ 两个开关（issue #60）：agent 与系统代理意图互不代替，各绑定持久化
    // 意图；agent 关闭会保留选择，系统代理关闭会清理匹配 NG2 端点的设置。
    Toggle("后台代理", isOn: agentToggleBinding)
    Toggle("设置系统代理", isOn: systemProxyToggleBinding)

    // ④ 模式选择（勾选态）：可选性与顺序来自 snapshot 的 Domain 单点策略。
    Picker("模式", selection: modeBinding) {
      ForEach(snapshot.availableModes, id: \.self) { mode in
        Text(mode.label).tag(mode)
      }
    }
    .pickerStyle(.inline)

    // 规则模式子选项（issue #63）：仅规则模式呈现。
    if snapshot.proxyMode == .rule {
      Picker("未匹配默认动作", selection: ruleDefaultActionBinding) {
        ForEach(RuleDefaultAction.allCases, id: \.self) { action in
          Text(action.label).tag(action)
        }
      }
      .pickerStyle(.inline)
    }

    // ⑤ 活动目标级联（只读）
    Menu("活动目标") {
      if targetTree.isEmpty {
        Text("目录为空")
      } else {
        TargetCascade(nodes: targetTree, activeTargetID: snapshot.activeTarget?.id)
      }
    }

    Divider()

    // ⑥ 退出：仅退 GUI；agent 由 launchd 持有，代理不受影响（构造上成立）。
    Button("退出 ShadowsocksX-NG2（代理仍在后台运行）") {
      NSApp.terminate(nil)
    }
  }

  /// 模式选择走同一控制 seam：切换语义与菜单勾选态由同一 snapshot 事实来源
  /// 保证一致（issue #47）。
  private var modeBinding: Binding<ProxyMode> {
    Binding(
      get: { control.snapshot.proxyMode },
      set: { mode in Task { await control.setProxyMode(mode) } })
  }

  /// 规则模式子选项（issue #63）：与首页共用同一控制 seam。
  private var ruleDefaultActionBinding: Binding<RuleDefaultAction> {
    Binding(
      get: { control.snapshot.ruleDefaultAction },
      set: { action in Task { await control.setRuleDefaultAction(action) } })
  }

  /// 两个开关绑定持久化意图（issue #60）；命令完成由 workflow 整体重发布。
  private var agentToggleBinding: Binding<Bool> {
    Binding(
      get: { control.snapshot.agentIntentEnabled },
      set: { enabled in Task { await control.setAgentEnabled(enabled) } })
  }

  private var systemProxyToggleBinding: Binding<Bool> {
    Binding(
      get: { control.snapshot.systemProxyIntentEnabled },
      set: { enabled in Task { await control.setSystemProxyEnabled(enabled) } })
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
