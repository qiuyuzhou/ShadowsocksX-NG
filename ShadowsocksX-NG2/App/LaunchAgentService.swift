import Foundation
import ServiceManagement

/// LaunchAgent 管理缝（spec #21 D2）：控制器经此协议启停 agent，单元测试以
/// fake 替换（真实 SMAppService 注册会改动用户登录项，不进单测）。
protocol LaunchAgentControlling {
  var status: LaunchAgentStatus { get }
  func register() throws
  func unregister() throws
}

/// 生产实现：plist 必须位于 app bundle `Contents/Library/LaunchAgents/`，
/// ProgramArguments 为 bundle 相对路径（launchd 按注册 app 的 bundle 解析）。
struct SMAppLaunchAgentService: LaunchAgentControlling {
  static let plistName = "com.qiuyuzhou.ShadowsocksX-NG.agent.plist"

  private let service = SMAppService.agent(plistName: Self.plistName)

  var status: LaunchAgentStatus {
    switch service.status {
    case .notRegistered:
      return .notRegistered
    case .enabled:
      return .registered
    case .requiresApproval:
      return .requiresApproval
    case .notFound:
      return .notFound
    @unknown default:
      return .notFound
    }
  }

  func register() throws {
    try service.register()
  }

  func unregister() throws {
    try service.unregister()
  }
}
