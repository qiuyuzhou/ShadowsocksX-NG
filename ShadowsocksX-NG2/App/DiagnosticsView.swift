import SwiftUI
import UniformTypeIdentifiers

/// 主窗口诊断区（spec #21 D11，issue #34/#43）：日志查看器（GUI 事件流实时
/// 呈现 + wrapper 收敛日志尾部，均可复制）与显式触发的脱敏诊断导出。事实
/// 采样、轮询代际与报告准备全部经 DiagnosticsWorkflow（issue #43 的唯一
/// UI-facing seam）；本视图只负责生命周期触发、呈现、剪贴板、保存面板与
/// 报告文件写入——文件实际写入成功后才登记导出完成事件。
struct DiagnosticsView: View {
  @ObservedObject var diagnostics: DiagnosticsWorkflow
  let errors: ErrorAlertPresenter

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
  @State private var exportedPath: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      sourcePicker
      Divider()
      logPane
    }
    .task { await diagnostics.readWhileActive() }
    .alert(
      "诊断已导出",
      isPresented: Binding(
        get: { exportedPath != nil },
        set: { if !$0 { exportedPath = nil } })
    ) {
      Button("好", role: .cancel) {}
    } message: {
      Text(exportedPath ?? "")
    }
  }

  // MARK: - 头部动作

  private var header: some View {
    HStack {
      Text("诊断").font(.headline)
      Spacer()
      Button {
        copyToClipboard(activeText)
      } label: {
        Label("复制", systemImage: "doc.on.doc")
      }
      .disabled(activeText.isEmpty)
      Button {
        exportReport()
      } label: {
        Label("导出诊断…", systemImage: "square.and.arrow.up")
      }
    }
    .padding(8)
  }

  private var sourcePicker: some View {
    Picker("日志来源", selection: $source) {
      ForEach(LogSource.allCases) { source in
        Text(source.label).tag(source)
      }
    }
    .pickerStyle(.segmented)
    .labelsHidden()
    .padding(8)
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

  @ViewBuilder
  private var logPane: some View {
    logText(activeLog.text, emptyMessage: activeLog.emptyMessage)
  }

  private func logText(_ text: String, emptyMessage: String) -> some View {
    ScrollView {
      LazyVStack(alignment: .leading, spacing: 2) {
        if text.isEmpty {
          Text(emptyMessage)
            .foregroundStyle(.secondary)
            .padding(12)
        } else {
          Text(text)
            .font(.system(size: 11, design: .monospaced))
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
        }
      }
    }
  }

  private var activeText: String {
    activeLog.text
  }

  private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  // MARK: - 显式导出（唯一导出入口）

  private func exportReport() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = diagnostics.suggestedReportFileName()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    switch diagnostics.prepareReport() {
    case .ready(let draft):
      do {
        try draft.data.write(to: url)
        diagnostics.noteExportCompleted()
        exportedPath = url.path
      } catch {
        errors.present(text: "导出失败：\(error.presentableMessage)")
      }
    case .failed:
      errors.present(text: "导出失败：诊断报告无法安全构造")
    }
  }
}

/// 诊断分区侧栏摘要（D11，story 25）：与详情共用 DiagnosticsWorkflow 的同一
/// 份安全摘要 projection。
struct DiagnosticsSummarySidebar: View {
  @ObservedObject var workflow: DiagnosticsWorkflow

  var body: some View {
    List {
      Section("状态摘要") {
        LabeledContent("代理状态", value: workflow.summary.proxyState.label)
        LabeledContent(
          "活动目标", value: workflow.summary.hasActiveTarget ? "已设置" : "未设置")
      }
      Section {
        Text(
          "日志可在右侧查看与复制；「导出诊断」生成仅含脱敏元数据的报告"
            + "（不含密码、插件参数、钥匙串值、订阅 URL、服务器地址与备注），"
            + "供报障时提供。"
        )
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .listStyle(.sidebar)
  }
}
