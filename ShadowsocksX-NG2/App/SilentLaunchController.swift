import SwiftUI

/// 静默启动偏好（ADR 0017）：启动时不呈现主窗口，直接以菜单栏形态后台运行。
/// 默认关；切换即持久化，当次会话无影响，下次启动生效。代理运行时恢复与
/// 登录项注册都不依赖它。持久化走独立的 SilentLaunchStore 而非 settings.json：
/// 代理控制器按内存快照整写该文件，旁路字段会被下一次整写覆盖。
@MainActor
final class SilentLaunchController: ObservableObject {
  @Published private(set) var isEnabled: Bool
  @Published private(set) var errorMessage: String?

  private let store: SilentLaunchStore

  init(store: SilentLaunchStore) {
    self.store = store
    isEnabled = store.loadSilentLaunchEnabled()
  }

  /// 先落盘后翻转内存态：持久化失败保持原值并点名原因，开关呈现不得与
  /// 下次启动的实际行为脱节。
  func setEnabled(_ enabled: Bool) {
    do {
      try store.save(silentLaunchEnabled: enabled)
      isEnabled = enabled
      errorMessage = nil
    } catch {
      errorMessage = error.presentableMessage
    }
  }
}
