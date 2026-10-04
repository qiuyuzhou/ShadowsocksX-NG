import SwiftUI

/// 服务器分区的分享与二维码呈现（issue #16/D10，地图 #52 票 #55）：
/// 复制 ss:// 与二维码弹窗；分享是显式命令，二维码在后台线程生成。
/// 2026-10-04 自详情区底部「复制 ss:// 链接」「二维码…」两按钮上收为分区
/// 工具栏「分享」按钮，作用于当前选中的服务器叶子：分组与空选择被 seam
/// 点名拒绝，凭据无法解析同样不可用，两者共用 nil 载荷这一 disabled 判据。
extension ServersView {
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

  /// 分享载荷：仅服务器叶子可产生（分组与未知节点被 seam 点名拒绝）；
  /// nil 即分享按钮不可用的统一判据。
  func sharePayload() -> String? {
    guard let selection else { return nil }
    return try? workflow.shareURI(for: selection)
  }

  func copySsUri() {
    guard let payload = sharePayload() else { return }
    do {
      try clipboard.write(payload)
    } catch {
      errors.present(error)
    }
  }

  func generateQR() {
    guard let payload = sharePayload() else { return }
    // 重置旧图：换选中项重开弹窗时先呈进度，不闪现上一台服务器的二维码。
    qrImage = nil
    showQR = true
    Task.detached(priority: .userInitiated) {
      let image = (try? QrCodeCodec.generatePNG(for: payload)).flatMap { NSImage(data: $0) }
      await MainActor.run {
        qrImage = image
      }
    }
  }
}
