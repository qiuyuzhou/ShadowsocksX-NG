import ServiceManagement
import SwiftUI

/// Legacy 交接确认与呈现面（issue #37，用户故事 7-9）：显式确认「切换到
/// 2.0」后才停用旧版后台服务；告知系统代理将被清理（需授权）且非 Legacy 代
/// 理不动；提示退出旧版 app（其 GUI 进程持有 PAC 端口）；Legacy 数据全部保
/// 留，残留与旧登录项给人工处理指引。
struct LegacyHandoffSheet: View {
  @ObservedObject var viewModel: LegacyHandoffViewModel
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text(title)
        .font(.title2.weight(.semibold))
      Text(
        "此操作会：停用旧版的三个后台服务（ss-local、Privoxy、kcptun，仅限这几个名字）；清理旧版写入的系统代理（需要授权，其他软件的代理配置不会被改动）。旧版的配置、日志、二进制等数据全部保留，可随时回退。"
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      switch viewModel.phase {
      case .idle:
        ProgressView().controlSize(.small)
      case .ready:
        detectionView
      case .performing:
        performingView
      case .completed:
        completedView
      case .failed(let reason):
        failedView(reason)
      }

      Spacer()
      footerButtons
    }
    .padding(24)
    .frame(width: 560, height: 620)
    .task {
      await viewModel.refresh()
    }
  }

  private var title: String {
    if case .completed = viewModel.phase { return "交接完成" }
    return viewModel.handoffCompleted ? "Legacy 交接状态" : "切换到 2.0"
  }

  // MARK: - 识别结果（确认前）

  @ViewBuilder
  private var detectionView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let detection = viewModel.detection {
          if detection.legacyAppRunning {
            legacyAppRunningCard
          }
          if !detection.printFailures.isEmpty {
            Label(
              "无法确认部分旧版服务状态：\(detection.printFailures.joined(separator: "、"))",
              systemImage: "exclamationmark.triangle.fill"
            )
            .foregroundStyle(.orange)
          }

          stateSection(title: "旧版后台服务（launchd）") {
            ForEach(LegacyLaunchAgentLabel.allCases, id: \.rawValue) { label in
              let loaded = detection.loadedLabels.contains(label.rawValue)
              HStack {
                Image(systemName: loaded ? "circle.fill" : "circle")
                  .foregroundStyle(loaded ? Color.orange : Color.secondary)
                  .font(.system(size: 8))
                Text(loaded ? "运行中：" + label.rawValue : "未加载：" + label.rawValue)
                  .font(.callout)
              }
            }
          }

          let residues = detection.plists.filter { $0.fileExists }
          if !residues.isEmpty {
            stateSection(title: "残留的旧版 LaunchAgent 配置（保留，不自动删除）") {
              ForEach(residues, id: \.label) { residue in
                Text(residueDescription(residue))
                  .font(.callout)
                  .foregroundStyle(
                    residue.isActiveForm ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
              }
            }
          }

          stateSection(title: "端口释放检查（交接完成前确认 1086/1087/1089 或自定义值）") {
            Text("旧版监听端口未释放时不会启动 2.0，避免端口冲突。")
              .font(.callout)
              .foregroundStyle(.secondary)
          }

          loginItemGuidance(detection: detection)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private var legacyAppRunningCard: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label(
        "旧版 ShadowsocksX-NG 正在运行", systemImage: "exclamationmark.triangle.fill"
      )
      .foregroundStyle(.orange)
      Text("请先退出旧版 app：它占用的 PAC 端口不会被后台服务的停用动作释放。")
        .font(.callout)
      Button("退出旧版应用") {
        viewModel.quitLegacyApp()
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
  }

  // MARK: - 执行中 / 完成 / 失败

  private var performingView: some View {
    VStack(alignment: .leading, spacing: 12) {
      ProgressView().controlSize(.small)
      Text("正在停用旧版后台服务并清理系统代理…")
        .font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var completedView: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 12) {
        if let report = viewModel.report {
          if !report.bootedOutLabels.isEmpty {
            Label(
              "已停用 \(report.bootedOutLabels.count) 个旧版后台服务",
              systemImage: "checkmark.circle.fill"
            )
            .foregroundStyle(.green)
            ForEach(report.bootedOutLabels, id: \.self) { label in
              Text(label).font(.callout).foregroundStyle(.secondary)
            }
          } else {
            Label("没有发现需要停用的旧版后台服务", systemImage: "checkmark.circle")
              .foregroundStyle(.secondary)
          }
          if !report.disabledLabels.isEmpty {
            Text(
              "已阻止 \(report.disabledLabels.count) 个残留配置在下次登录时自动加载。"
            )
            .font(.callout)
          }
          if !report.proxyServicesCleaned.isEmpty {
            Text("已清理 \(report.proxyServicesCleaned.count) 个网络服务的旧版系统代理配置。")
              .font(.callout)
          }
          if !report.proxyServicesUntouchedUnknownOwner.isEmpty {
            Text(
              "以下网络服务的代理配置不属于旧版，未改动："
                + report.proxyServicesUntouchedUnknownOwner.joined(separator: "、")
            )
            .font(.callout)
            .foregroundStyle(.orange)
          }
          if !report.confirmedFreePorts.isEmpty {
            Text(
              "端口 \(report.confirmedFreePorts.map(String.init).joined(separator: "、")) 已释放，2.0 代理正在启动。"
            )
            .font(.callout)
          }
          if !report.residue.isEmpty {
            Divider()
            Text("Legacy 数据全部保留，可随时回退。以下残留建议之后手动处理：")
              .font(.callout)
            ForEach(report.residue, id: \.label) { residue in
              Text(
                "• ~/Library/LaunchAgents/\(residue.label).plist"
                  + residueDetailSuffix(residue)
              )
              .font(.callout)
              .foregroundStyle(.secondary)
            }
          }
          Divider()
          loginItemGuidanceIfKnown()
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
  }

  private func failedView(_ reason: String) -> some View {
    VStack(alignment: .leading, spacing: 12) {
      Label("交接未完成", systemImage: "xmark.octagon.fill")
        .foregroundStyle(.red)
      Text(reason)
        .font(.callout)
      Text("已执行的动作不会回滚（已停用的服务保持停用）；解决上面的问题后可重新执行交接。")
        .font(.callout)
        .foregroundStyle(.secondary)
      Button("重新检查") {
        Task { await viewModel.refresh() }
      }
      .controlSize(.small)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  // MARK: - 登录项指引（无编程停用路径，仅人工）

  @ViewBuilder
  private func loginItemGuidance(detection: LegacyHandoffDetection) -> some View {
    stateSection(title: "旧版的开机自启动需要手动关闭") {
      Text(
        detection.legacyAppInstalled
          ? "打开 系统设置 → 通用 → 登录项与扩展，移除 ShadowsocksX-NG（或其 LaunchHelper）条目；也可以打开旧版 app，在偏好设置中关闭「登录时启动」。"
          : "若曾使用旧版的开机自启动：打开 系统设置 → 通用 → 登录项与扩展，移除 ShadowsocksX-NG（或其 LaunchHelper）条目。"
      )
      .font(.callout)
      .foregroundStyle(.secondary)
      Button("打开系统设置的登录项面板") {
        openLoginItemsSettings()
      }
      .controlSize(.small)
    }
  }

  @ViewBuilder
  private func loginItemGuidanceIfKnown() -> some View {
    if let detection = viewModel.detection {
      loginItemGuidance(detection: detection)
    }
  }

  // MARK: - 底部按钮

  @ViewBuilder
  private var footerButtons: some View {
    HStack {
      Button("关闭") { dismiss() }
      Spacer()
      if case .ready = viewModel.phase {
        Button("切换到 2.0") {
          Task { await viewModel.performHandoff() }
        }
        .keyboardShortcut(.defaultAction)
        .disabled(!viewModel.canConfirm)
      }
    }
  }

  private func stateSection<Content: View>(
    title: String?, @ViewBuilder content: () -> Content
  ) -> some View {
    VStack(alignment: .leading, spacing: 6) {
      if let title {
        Text(title)
          .font(.headline)
      }
      content()
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(12)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
  }

  /// 残留 plist 的一行说明：活跃性必须读内容判断（2017 前的生成代码带
  /// KeepAlive，会登录自启）；读不出内容时如实说明，不冒充休眠。
  private func residueDescription(_ residue: LegacyAgentPlistResidue) -> String {
    if !residue.contentReadable {
      return "\(residue.label)：存在但内容无法读取，无法判断活跃性；交接将阻止其加载，建议之后手动检查删除"
    }
    return residue.isActiveForm
      ? "\(residue.label)：含 KeepAlive/RunAtLoad，会在登录时自动运行；交接将阻止其再次加载，建议之后手动删除该文件"
      : "\(residue.label)：休眠残留（登录时仅注册、不运行）；交接将阻止其再次加载"
  }

  private func residueDetailSuffix(_ residue: LegacyAgentPlistResidue) -> String {
    if !residue.contentReadable { return "（内容无法读取）" }
    return residue.isActiveForm ? "（含 KeepAlive/RunAtLoad，交接已阻止其加载）" : ""
  }

  private func openLoginItemsSettings() {
    SMAppService.openSystemSettingsLoginItems()
  }
}
