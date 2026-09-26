import SwiftUI

/// 首页分区（地图 #52，票 #54）：代理模式切换、运行控制、当前服务器目标树
/// 与快速操作。模式与两个开关（agent/系统代理，issue #60）走代理控制工作流
/// 的整体 snapshot；目标树与激活走目录工作流 projection 与 `activate`；复制
/// HTTP 导出是 UI 副作用。三种模式（规则/全局/直连）与规则子选项共用同一快照。
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
      "按内置规则在代理与直连间选择；未匹配目标走默认动作。"
    case .global:
      "所有系统代理流量通过本地 SOCKS5 端点转发，不使用规则分流。"
    case .direct:
      "通过本地 SOCKS 与 HTTP 入口直连，不使用 Shadowsocks 服务器。"
    }
  }
}
