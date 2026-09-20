import SwiftUI
import UniformTypeIdentifiers

/// 主窗口诊断区（spec #21 D11，issue #34）：日志查看器（GUI 事件流实时呈现 +
/// wrapper 收敛日志尾部，均可复制）与显式触发的脱敏诊断导出。导出仅由用户
/// 点击触发，内容只含 D5 允许的元数据类目。
struct DiagnosticsView: View {
  @ObservedObject var viewModel: CatalogViewModel
  @ObservedObject var proxyController: ProxyRuntimeController
  let eventStore: RuntimeEventStore

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
  @State private var guiLines: [String] = []
  @State private var agentLogText: String?
  @State private var exportedPath: String?

  var body: some View {
    VStack(spacing: 0) {
      header
      Divider()
      sourcePicker
      Divider()
      logPane
    }
    .task { await refreshLoop() }
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

  @ViewBuilder
  private var logPane: some View {
    switch source {
    case .guiEvents:
      logText(
        guiLines.joined(separator: "\n"),
        emptyMessage: "暂无 GUI 事件；开关代理或激活服务器后，运行事件会实时出现在这里。")
    case .agentLog:
      logText(
        agentLogText ?? "",
        emptyMessage:
          "暂无运行日志；代理运行时（wrapper）启动后，它与 sslocal 的输出会收敛到 agent.log 并在此呈现。"
      )
    }
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

  // MARK: - 实时刷新

  /// 两个日志来源都以轮询刷新（GUI 事件走内存缓冲，agent.log 走尾部读取），
  /// 一秒粒度对诊断足够，也避免引入跨线程 @Published。
  private func refreshLoop() async {
    while !Task.isCancelled {
      guiLines = eventStore.snapshot.map(\.renderedLine)
      agentLogText = AgentLogTail.readLastLines(of: RuntimePaths.agentLogURL())
      try? await Task.sleep(for: .seconds(1))
    }
  }

  private var activeText: String {
    switch source {
    case .guiEvents:
      return guiLines.joined(separator: "\n")
    case .agentLog:
      return agentLogText ?? ""
    }
  }

  private func copyToClipboard(_ text: String) {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
  }

  // MARK: - 显式导出（唯一导出入口）

  private func exportReport() {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.plainText]
    panel.nameFieldStringValue = "ShadowsocksX-NG-诊断-\(fileStamp()).txt"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    do {
      let report = DiagnosticReportBuilder.markdown(from: makeSnapshot())
      guard let data = report.data(using: .utf8) else {
        viewModel.presentedError = "导出失败：报告无法编码为 UTF-8"
        return
      }
      try data.write(to: url)
      RuntimeLog.emit(.diagnosticsExported)
      exportedPath = url.path
    } catch {
      viewModel.presentedError = "导出失败：\(error.localizedDescription)"
    }
  }

  private func makeSnapshot() -> DiagnosticSnapshot {
    var snapshot = DiagnosticSnapshot()
    snapshot.appVersion = Self.appVersion()
    snapshot.systemSummary = Self.systemSummary()
    snapshot.proxyState = proxyController.diagnosticState
    snapshot.hasActiveTarget = proxyController.isActiveTargetPresent
    snapshot.listen = proxyController.listenSettings
    snapshot.runtimeDocumentSummary = proxyController.runtimeDocumentSummary()
    snapshot.catalog = viewModel.catalog
    snapshot.fileFacts = Self.fileFacts()
    snapshot.eventLines = eventStore.snapshot.suffix(200).map(\.renderedLine)
    snapshot.homePathForRedaction = NSHomeDirectory()
    return snapshot
  }

  private static func fileFacts() -> [DiagnosticFileFacts] {
    [
      DiagnosticFileCollector.collect(label: "v2 目录", url: RuntimePaths.v2Directory()),
      DiagnosticFileCollector.collect(
        label: "catalog.json", url: CatalogFileStore.defaultFileURL()),
      DiagnosticFileCollector.collect(
        label: "activation.json", url: ActivationStateFileStore.defaultFileURL()),
      DiagnosticFileCollector.collect(
        label: "sslocal-active.json", url: RuntimePaths.runtimeFileURL()),
      DiagnosticFileCollector.collect(label: "agent.pid", url: RuntimePaths.agentPIDFileURL()),
      DiagnosticFileCollector.collect(label: "agent.log", url: RuntimePaths.agentLogURL()),
    ]
  }

  private static func appVersion() -> String? {
    guard let info = Bundle.main.infoDictionary else { return nil }
    let parts = [
      (info["CFBundleShortVersionString"] as? String).map { "版本 \($0)" },
      (info["CFBundleVersion"] as? String).map { "构建 \($0)" },
    ].compactMap { $0 }
    return parts.isEmpty ? nil : parts.joined(separator: "，")
  }

  private static func systemSummary() -> String {
    let arch: String
    #if arch(arm64)
      arch = "arm64"
    #elseif arch(x86_64)
      arch = "x86_64"
    #else
      arch = "未知架构"
    #endif
    return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)，\(arch)"
  }

  private func fileStamp() -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    return formatter.string(from: Date())
  }
}

extension ProxyRuntimeController {
  /// 控制器状态 → 诊断安全呈现（D5：不透传任意错误 detail；监听地址只以
  /// 回环/非回环两态进入导出，原始错误文本一律丢弃）。
  var diagnosticState: DiagnosticProxyState {
    switch state {
    case .off:
      return .off
    case .starting:
      return .starting
    case .running:
      return .running
    case .firewallBlocked:
      return .firewallBlocked
    case .launchFailed:
      return .launchFailed
    case .activationFailed(let reason):
      return .activationFailed(reason: reason)
    case .requiresApproval:
      return .requiresApproval
    case .serviceFailed:
      return .serviceFailed
    case .systemProxyFailed:
      return .systemProxyFailed
    }
  }
}

/// 诊断分区侧栏摘要（D11）：代理状态一览与脱敏说明。
struct DiagnosticsSummarySidebar: View {
  @ObservedObject var proxyController: ProxyRuntimeController

  var body: some View {
    List {
      Section("状态摘要") {
        LabeledContent("代理状态", value: proxyController.diagnosticState.label)
        LabeledContent(
          "活动目标", value: proxyController.isActiveTargetPresent ? "已设置" : "未设置")
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
