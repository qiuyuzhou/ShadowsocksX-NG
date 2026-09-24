import SwiftUI

/// 主窗口诊断区（spec #21 D11，issue #34/#43，地图 #52 票 #58）：按原型重排
/// 为状态摘要卡（代理状态、活动目标）+ 日志卡（GUI 事件流实时呈现 + wrapper
/// 收敛日志尾部，来源切换 segmented、可复制）+ 底部脱敏说明行。导出诊断动作
/// 在窗口工具栏（由主窗口壳提供，保持 DiagnosticReportExportAction 既有
/// 入口）。事实采样、轮询代际与报告准备全部经 DiagnosticsWorkflow（issue #43
/// 的唯一 UI-facing seam）；本视图只负责生命周期触发、呈现与复制动作。
struct DiagnosticsView: View {
  @ObservedObject var diagnostics: DiagnosticsWorkflow
  let errors: ErrorAlertPresenter
  let clipboard: any TextClipboard

  enum LogSource: String, CaseIterable, Identifiable {
    case guiEvents
    case agentLog

    var id: Self { self }

    var label: String {
      switch self {
      case .guiEvents:
        return "GUI 事件"
      case .agentLog:
        return "运行日志（wrapper）"
      }
    }
  }

  @State private var source: LogSource = .guiEvents

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 20) {
        summaryRow
        logCard
        Text(
          "诊断导出只包含状态、存在性、权限和脱敏元数据，不包含密码、插件参数、"
            + "订阅 URL 或运行时 JSON。"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
      .frame(maxWidth: 960, alignment: .leading)
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(.leading, 28)
      .padding(.trailing, 32)
      .padding(.top, 24)
      .padding(.bottom, 36)
    }
    .task { await diagnostics.readWhileActive() }
  }

  // MARK: - 状态摘要

  private var summaryRow: some View {
    HStack(alignment: .top, spacing: 14) {
      statCard("代理状态", value: diagnostics.summary.proxyState.label)
      statCard("活动目标", value: diagnostics.summary.hasActiveTarget ? "已设置" : "未设置")
    }
  }

  private func statCard(_ label: String, value: String) -> some View {
    VStack(alignment: .leading, spacing: 4) {
      Text(label)
        .font(.caption)
        .foregroundStyle(.secondary)
      Text(value)
        .font(.callout.weight(.semibold))
        .lineLimit(2)
        .help(value)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .background.secondary,
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.quaternary)
    )
  }

  // MARK: - 日志卡

  private var logCard: some View {
    VStack(alignment: .leading, spacing: 0) {
      HStack(spacing: 12) {
        Picker("日志来源", selection: $source) {
          ForEach(LogSource.allCases) { source in
            Text(source.label).tag(source)
          }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .frame(width: 320)
        Spacer(minLength: 12)
        Button {
          copyToClipboard(activeText)
        } label: {
          Label("复制", systemImage: "doc.on.doc")
        }
        .disabled(activeText.isEmpty)
      }
      .padding(.horizontal, 16)
      .padding(.vertical, 12)
      Divider()
      logBox
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(
      .background.secondary,
      in: RoundedRectangle(cornerRadius: 12, style: .continuous)
    )
    .overlay(
      RoundedRectangle(cornerRadius: 12, style: .continuous)
        .strokeBorder(.quaternary)
    )
  }

  /// 当前日志来源的文本与空态提示（呈现与复制共用同一来源，story 21）。
  private var activeLog: (text: String, emptyMessage: String) {
    switch source {
    case .guiEvents:
      return (
        diagnostics.logView.guiEventLines.joined(separator: "\n"),
        "暂无 GUI 事件；开关代理或激活服务器后，运行事件会实时出现在这里。"
      )
    case .agentLog:
      return (
        diagnostics.logView.agentLogTail ?? "",
        "暂无运行日志；代理运行时（wrapper）启动后，它与 sslocal 的输出会收敛到 agent.log 并在此呈现。"
      )
    }
  }

  private var activeText: String {
    activeLog.text
  }

  private var logBox: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 2) {
        if activeText.isEmpty {
          Text(activeLog.emptyMessage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(16)
        } else {
          Text(activeText)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.primary)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .frame(minHeight: 300, maxHeight: 390)
  }

  private func copyToClipboard(_ text: String) {
    do {
      try clipboard.write(text)
    } catch {
      errors.present(error)
    }
  }
}
