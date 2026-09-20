import SwiftUI
import UniformTypeIdentifiers

/// 「通过 URL 导入」表单（issue #32 添加入口之二）：粘贴 ss:// 链接（每行一条），
/// 与剪贴板入口共用视图模型的批量落点。
struct ImportURLSheet: View {
  @ObservedObject var viewModel: CatalogViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var text = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("粘贴 ss:// 链接，每行一条；无法解析的行会点名报告。")
        .font(.callout)
        .foregroundStyle(.secondary)
      TextEditor(text: $text)
        .font(.monospaced(.callout)())
        .frame(minWidth: 460, minHeight: 140)
        .overlay(
          RoundedRectangle(cornerRadius: 6)
            .strokeBorder(.separator)
        )
      HStack {
        Button("粘贴自剪贴板") {
          if let clipboard = NSPasteboard.general.string(forType: .string) {
            text = clipboard
          }
        }
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("导入") { importText() }
          .keyboardShortcut(.defaultAction)
          .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
      }
    }
    .padding(20)
    .frame(minWidth: 520, minHeight: 260)
  }

  private func importText() {
    let parent = viewModel.importTargetParent(for: viewModel.selectedNodeID)
    Task {
      do {
        let outcome = try await viewModel.addServers(fromURIs: text, into: parent)
        if !outcome.failures.isEmpty {
          viewModel.presentedError =
            "已添加 \(outcome.added) 台服务器；以下条目无法解析：\n"
            + outcome.failures.joined(separator: "\n")
        }
        dismiss()
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }
}

/// 「从二维码图片识别」表单（issue #32 添加入口之三）：文件选择 + 拖图入窗。
/// 屏幕扫码明确不做（spec #21）；识别结果按全新身份导入，不与既有节点合并去重。
struct QRImportSheet: View {
  @ObservedObject var viewModel: CatalogViewModel
  @Environment(\.dismiss) private var dismiss

  @State private var detectedURIs: [String] = []
  @State private var decodeFailures: [String] = []
  @State private var showFileImporter = false
  @State private var hovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      dropZone
      Button("选择图片文件…") { showFileImporter = true }
      if !decodeFailures.isEmpty {
        Text("无法识别：\(decodeFailures.joined(separator: "、"))")
          .font(.footnote)
          .foregroundStyle(.secondary)
      }
      if !detectedURIs.isEmpty {
        Text("识别到 \(detectedURIs.count) 条 ss:// 链接：")
          .font(.callout)
        ForEach(detectedURIs, id: \.self) { uri in
          Text(uri)
            .font(.monospaced(.footnote)())
            .lineLimit(1)
            .truncationMode(.middle)
            .help(uri)
        }
        HStack {
          Spacer()
          Button("清除") { detectedURIs = [] }
          Button("导入 \(detectedURIs.count) 台服务器") { importDetected() }
            .keyboardShortcut(.defaultAction)
        }
      }
      Spacer()
    }
    .padding(20)
    .frame(minWidth: 480, minHeight: 300)
    .fileImporter(
      isPresented: $showFileImporter,
      allowedContentTypes: [.image],
      allowsMultipleSelection: true
    ) { result in
      let urls = (try? result.get()) ?? []
      processImageSources(urls.map { try? Data(contentsOf: $0) })
    }
  }

  private var dropZone: some View {
    VStack(spacing: 8) {
      Image(systemName: "photo.on.rectangle.angled")
        .font(.system(size: 36))
        .foregroundStyle(hovering ? .orange : .secondary)
      Text("把二维码图片拖到这里")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity)
    .frame(height: 120)
    .background(
      RoundedRectangle(cornerRadius: 10)
        .fill(hovering ? Color.orange.opacity(0.08) : Color.primary.opacity(0.03))
    )
    .overlay(
      RoundedRectangle(cornerRadius: 10)
        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [5]))
        .foregroundStyle(hovering ? AnyShapeStyle(Color.orange) : AnyShapeStyle(.separator))
    )
    .dropDestination(for: Data.self) { payloads, _ in
      processImageSources(payloads)
      return !payloads.isEmpty
    } isTargeted: {
      hovering = $0
    }
  }

  /// 逐张识别二维码文本负载，仅保留 ss:// 行；非图片或无负载的来源点名。
  private func processImageSources(_ sources: [Data?]) {
    Task.detached(priority: .userInitiated) {
      var uris: [String] = []
      var failures: [String] = []
      for (index, data) in sources.enumerated() {
        guard let data else {
          failures.append("来源 \(index + 1)（不是可用图片）")
          continue
        }
        let payloads = (try? QrCodeCodec.detectPayloads(in: data)) ?? []
        let ssPayloads = payloads.filter { $0.lowercased().hasPrefix("ss://") }
        if ssPayloads.isEmpty {
          failures.append("来源 \(index + 1)（未识别到 ss:// 二维码）")
        } else {
          uris.append(contentsOf: ssPayloads)
        }
      }
      await MainActor.run {
        detectedURIs.append(contentsOf: uris)
        decodeFailures = failures
      }
    }
  }

  private func importDetected() {
    let parent = viewModel.importTargetParent(for: viewModel.selectedNodeID)
    Task {
      do {
        let text = detectedURIs.joined(separator: "\n")
        let outcome = try await viewModel.addServers(fromURIs: text, into: parent)
        if !outcome.failures.isEmpty {
          viewModel.presentedError =
            "已添加 \(outcome.added) 台服务器；以下条目无法解析：\n"
            + outcome.failures.joined(separator: "\n")
        }
        dismiss()
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }
}

/// 「移动到」表单：目的地为目录根与除自身子树外的全部手动组（跨来源与成环
/// 由领域层最终拒绝）。
struct MoveNodeSheet: View {
  @ObservedObject var viewModel: CatalogViewModel
  let nodeID: NodeID
  @Environment(\.dismiss) private var dismiss

  @State private var destination: NodeID?

  private struct Destination: Identifiable {
    let id: NodeID?
    let title: String
  }

  private var destinations: [Destination] {
    var result = [Destination(id: nil, title: "目录根")]
    func walk(_ nodes: [SidebarNode], depth: Int) {
      for node in nodes {
        guard node.isGroup, node.source == .manual else { continue }
        let ancestors = viewModel.catalog.ancestors(of: node.id)
        guard node.id != nodeID, !ancestors.contains(nodeID) else { continue }
        let indent = String(repeating: "    ", count: depth)
        result.append(Destination(id: node.id, title: indent + node.name))
        walk(node.children ?? [], depth: depth + 1)
      }
    }
    walk(viewModel.sidebarNodes(), depth: 0)
    return result
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("把「\(viewModel.displayName(for: nodeID))」移动到：")
        .font(.callout)
      Picker(
        "目的地",
        selection: Binding(
          get: { destination ?? destinations.first?.id },
          set: { destination = $0 }
        )
      ) {
        ForEach(destinations) { target in
          Text(target.title).tag(target.id as NodeID?)
        }
      }
      .pickerStyle(.radioGroup)
      HStack {
        Spacer()
        Button("取消", role: .cancel) { dismiss() }
        Button("移动") { move() }
          .keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(minWidth: 380)
  }

  private func move() {
    Task {
      do {
        try await viewModel.move(nodeID, to: destination)
        dismiss()
      } catch {
        viewModel.presentedError = error.presentableMessage
      }
    }
  }
}
