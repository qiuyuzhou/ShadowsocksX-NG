import SwiftUI

/// 服务器分区的分享与二维码呈现（issue #16/D10，地图 #52 票 #55；2026-10-05
/// 按草图自工具栏 popover 升级为 sheet，docs/design/server-share-sheet.md）：
/// 大幅二维码加复制图片、保存图片、复制 ss:// 三条通路。分享是显式命令，
/// 作用于打开时选中的服务器叶子，载荷与建议文件名随 ShareContext 冻结，
/// sheet 生命周期内不随选择漂移。
extension ServersView {
  /// 打开 sheet 即冻结的分享载荷与保存面板建议名。
  struct ShareContext: Identifiable {
    let payload: String
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
    guard let selection, let payload = try? workflow.shareURI(for: selection) else { return }
    shareContext = ShareContext(
      payload: payload,
      suggestedFileName: QrImageSaveDraft.suggestedFileName(
        from: workflow.displayName(for: selection)))
  }
}

/// 分享 sheet 本体：草图的顶部说明加大幅二维码，三个动作按钮纵向铺满，
/// 「完成」收尾；两个复制动作给瞬时「已复制」反馈，保存由系统面板反馈。
struct ShareServerSheet: View {
  let payload: String
  let suggestedFileName: String
  let imageClipboard: any ImageClipboard
  let textClipboard: any TextClipboard
  let saver: any QrImageSaver
  let errors: ErrorAlertPresenter

  @Environment(\.dismiss) private var dismiss
  @State private var png: Data?
  @State private var copyFeedback: CopyFeedback = .none
  @State private var feedbackResetTask: Task<Void, Never>?

  enum CopyFeedback: Equatable {
    case none
    case image
    case link
  }

  /// 四枚按钮统一最小宽：所有标签（含「已复制」反馈态）都远小于该值，保证
  /// 视觉等宽，且按草图略窄于二维码块（minWidth 施于标签内侧，bordered 样式
  /// 随标签边界绘制）。
  private static let buttonMinWidth: CGFloat = 260

  var body: some View {
    VStack(spacing: 16) {
      Text("用其他设备的客户端扫描此二维码")
        .font(.headline)
      qrDisplay
      VStack(spacing: 8) {
        shareButton("复制二维码图片", feedback: .image, disabled: png == nil) {
          copyImage()
        }
        shareButton("保存二维码图片", feedback: nil, disabled: png == nil) {
          saveImage()
        }
        // ss:// 链接不依赖二维码生成，sheet 打开即可复制。
        shareButton("复制 ss:// 链接", feedback: .link, disabled: false) {
          copySsUri()
        }
      }
      Button {
        dismiss()
      } label: {
        Text("完成")
          .frame(minWidth: Self.buttonMinWidth)
      }
      .keyboardShortcut(.cancelAction)
      .buttonStyle(.bordered)
    }
    .padding(24)
    .frame(width: 340)
    .task { await generate() }
    .onDisappear { feedbackResetTask?.cancel() }
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
    feedback: CopyFeedback?,
    disabled: Bool,
    action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      Group {
        if let feedback, copyFeedback == feedback {
          Label("已复制", systemImage: "checkmark")
        } else {
          Text(title)
        }
      }
      .frame(minWidth: Self.buttonMinWidth)
    }
    .buttonStyle(.bordered)
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
