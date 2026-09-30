import Foundation

/// 构建产物定位：沿测试 bundle 落盘位置向上查找 app 产物。覆盖两种布局——
/// TEST_HOST 过渡期 `.xctest` 嵌在 app bundle 的 `Contents/PlugIns/` 内，
/// 去宿主化后 `.xctest` 与 `.app` 平级同在 `Build/Products/<config>/`。
/// 测试需要 app 产物（嵌入二进制、Info.plist 打包面断言）时一律经此定位，
/// 不得用 `Bundle.main`（去宿主化后它是 xctest runner 的 bundle）。
enum AppArtifact {
  static let bundleURL: URL = {
    var directory = Bundle(for: Marker.self).bundleURL
    while directory.path != "/" {
      directory.deleteLastPathComponent()
      if directory.lastPathComponent == "ShadowsocksX-NG2.app" {
        return directory
      }
    }
    // 定位失败时返回原目录让用例以「产物缺失」失败并暴露实际路径，不炸进程。
    return Bundle(for: Marker.self).bundleURL
  }()

  /// `Bundle(for:)` 需要类对象；marker 只为取得测试 bundle 的落盘位置。
  private final class Marker {}
}
