import SwiftUI

/// 服务器分享由工具栏按钮旁的 popover 呈现；打开时冻结已保存资料和载荷。
extension ServersView {
  /// 打开 popover 即冻结的分享载荷、资料与保存面板建议名。
  struct ShareContext: Identifiable {
    let payload: String
    let presentation: ServerSharePresentation
    let suggestedFileName: String
    var id: String { payload }
  }

  /// 分享载荷：仅服务器叶子可产生（分组与未知节点被 seam 点名拒绝）；
  /// nil 即分享按钮不可用的统一判据。
  func sharePayload() -> String? {
    guard let selection else { return nil }
    return try? workflow.shareURI(for: selection)
  }

  func presentShare() {
    guard let selection,
      let presentation = workflow.serverSharePresentation(for: selection),
      let payload = try? workflow.shareURI(for: selection)
    else { return }
    shareContext = ShareContext(
      payload: payload,
      presentation: presentation,
      suggestedFileName: QrImageSaveDraft.suggestedFileName(
        from: presentation.name))
  }
}

/// 系统分享菜单式分区：服务器资料、二维码、带图标的操作行。
struct ShareServerPopover: View {
  let payload: String
  let presentation: ServerSharePresentation
  let suggestedFileName: String
  let imageClipboard: any ImageClipboard
  let textClipboard: any TextClipboard
  let saver: any QrImageSaver
  let errors: ErrorAlertPresenter

  @State private var png: Data?
  @State private var copyFeedback: CopyFeedback = .none
  @State private var feedbackResetTask: Task<Void, Never>?

  enum CopyFeedback: Equatable {
    case none
    case image
    case link
  }

  var body: some View {
    VStack(spacing: 12) {
      serverSummary
        .padding(.horizontal, 8)
      Divider()
      qrDisplay
      Divider()
      VStack(spacing: 2) {
        shareButton(
          "保存二维码图片", symbol: "square.and.arrow.down", feedback: nil,
          disabled: png == nil
        ) {
          saveImage()
        }
        shareButton(
          "拷贝二维码图片", symbol: "doc.on.doc", feedback: .image,
          disabled: png == nil
        ) {
          copyImage()
        }
        shareButton("拷贝 URI 链接", symbol: "link", feedback: .link, disabled: false) {
          copySsUri()
        }
      }
    }
    .padding(12)
    .frame(width: 324)
    .task { await generate() }
    .onDisappear { feedbackResetTask?.cancel() }
  }

  private var serverSummary: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(verbatim: presentation.name)
        .font(.headline)
      Text(verbatim: endpoint)
        .foregroundStyle(.secondary)
      Text("加密方式：\(presentation.encryptionMethod)")
      if let plugin = presentation.pluginProgram, !plugin.isEmpty {
        Text("插件：\(plugin)")
      }
    }
    .lineLimit(1)
    .truncationMode(.tail)
    .frame(maxWidth: .infinity, alignment: .leading)
  }

  private var endpoint: String {
    let address = presentation.address
    let host = address.contains(":") && !address.hasPrefix("[") ? "[\(address)]" : address
    return "\(host):\(presentation.port)"
  }

  private var qrDisplay: some View {
    Group {
      if let png, let image = NSImage(data: png) {
        Image(nsImage: image)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 280, height: 280)
      } else {
        ProgressView()
          .frame(width: 280, height: 280)
      }
    }
    // 白底衬底保证深色外观下的扫码对比度；阴影让浅色外观下也有边界。
    .padding(10)
    .background(
      RoundedRectangle(cornerRadius: 10, style: .continuous)
        .fill(Color.white)
        .shadow(color: .black.opacity(0.15), radius: 2, y: 1)
    )
  }

  private func shareButton(
    _ title: String,
    symbol: String,
    feedback: CopyFeedback?,
    disabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 12) {
        Image(systemName: copyFeedback == feedback ? "checkmark" : symbol)
          .frame(width: 20)
        Text(copyFeedback == feedback ? "已复制" : title)
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 8)
      .padding(.vertical, 7)
      .contentShape(Rectangle())
    }
    .buttonStyle(ShareActionButtonStyle())
    .disabled(disabled)
  }

  /// 二维码在后台线程生成（重置即先呈进度，不闪现上一台服务器的码）。
  private func generate() async {
    let payload = payload
    let data = await Task.detached(priority: .userInitiated) {
      try? QrCodeCodec.generatePNG(for: payload)
    }.value
    png = data
  }

  private func copyImage() {
    guard let png else { return }
    do {
      try imageClipboard.write(png)
      flash(.image)
    } catch {
      errors.present(error)
    }
  }

  private func saveImage() {
    guard let png else { return }
    switch saver.save(QrImageSaveDraft(data: png, suggestedFileName: suggestedFileName)) {
    case .cancelled, .saved:
      break  // 保存与取消都由系统面板给出反馈
    case .failed(let failure):
      errors.present(failure)
    }
  }

  private func copySsUri() {
    do {
      try textClipboard.write(payload)
      flash(.link)
    } catch {
      errors.present(error)
    }
  }

  /// 复制成功反馈：标签短暂换成「已复制」，重复点击重置计时。
  private func flash(_ feedback: CopyFeedback) {
    copyFeedback = feedback
    feedbackResetTask?.cancel()
    feedbackResetTask = Task {
      try? await Task.sleep(for: .seconds(2))
      guard !Task.isCancelled else { return }
      copyFeedback = .none
    }
  }
}

/// 保留原生 Button 的键盘与辅助功能，悬停时绘制系统菜单式行底色。
private struct ShareActionButtonStyle: ButtonStyle {
  @Environment(\.isEnabled) private var isEnabled
  @State private var isHovering = false

  func makeBody(configuration: Configuration) -> some View {
    configuration.label
      .background {
        RoundedRectangle(cornerRadius: 6)
          .fill(
            Color.primary.opacity(isEnabled && (isHovering || configuration.isPressed) ? 0.1 : 0))
      }
      .opacity(isEnabled ? 1 : 0.4)
      .onHover { isHovering = $0 }
  }
}
