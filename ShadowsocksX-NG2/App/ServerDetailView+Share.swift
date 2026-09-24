import SwiftUI

/// 服务器详情的分享与二维码呈现（issue #16/D10，地图 #52 票 #55）：
/// 复制 ss:// 与二维码弹窗；分享是显式命令，二维码在后台线程生成。
extension ServerDetailView {
  var qrPopover: some View {
    VStack(spacing: 12) {
      if let qrImage {
        Image(nsImage: qrImage)
          .interpolation(.none)
          .resizable()
          .scaledToFit()
          .frame(width: 220, height: 220)
      } else {
        ProgressView()
          .frame(width: 220, height: 220)
      }
      Text("用其他设备的客户端扫描此二维码")
        .font(.footnote)
        .foregroundStyle(.secondary)
      Button("复制 ss:// 链接") { copySsUri() }
    }
    .padding(20)
  }

  func qrPayload() -> String? {
    try? workflow.shareURI(for: serverID)
  }

  func copySsUri() {
    do {
      try clipboard.write(workflow.shareURI(for: serverID))
    } catch {
      errors.present(error)
    }
  }

  func generateQR() {
    guard let payload = qrPayload() else { return }
    showQR = true
    Task.detached(priority: .userInitiated) {
      let image = (try? QrCodeCodec.generatePNG(for: payload)).flatMap { NSImage(data: $0) }
      await MainActor.run {
        qrImage = image
      }
    }
  }
}
