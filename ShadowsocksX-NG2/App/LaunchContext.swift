import Foundation

/// 进程启动来源判定（启动策略的输入，CONTEXT.md「Background form」不变量）。
/// macOS 没有「本次因登录项而启动」的系统 API（SMAppService 只暴露注册态，
/// 不暴露启动原因），故采用社区标准启发式：登录项已启用且距开机很近。
/// 误判边界：登录项启用时，开机后窗口期内手动启动也会被按登录启动对待
/// （静默不开主窗口）；主窗口从状态菜单随时可开，损失可接受。
enum LaunchContext {
  /// 判定窗口期：须覆盖慢启动（FileVault 解密、慢外设枚举），同时尽量
  /// 压缩手动启动的误判面。
  static let loginLaunchWindow: TimeInterval = 120

  static func isLoginItemLaunch(
    loginItemEnabled: Bool,
    systemUptime: TimeInterval
  ) -> Bool {
    guard loginItemEnabled else { return false }
    return systemUptime < loginLaunchWindow
  }
}
