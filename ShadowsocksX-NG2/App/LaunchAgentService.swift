import Foundation
import ServiceManagement

/// LaunchAgent 管理缝（spec #21 D2）：控制器经此协议启停 agent，单元测试以
/// fake 替换（真实 SMAppService 注册会改动用户登录项，不进单测）。
protocol LaunchAgentControlling {
  var status: LaunchAgentStatus { get }
  func register() throws
  func unregister() throws
}

/// 生产实现：注册时从 bundle 内模板 plist 生成带绝对 ProgramArguments 的
/// 临时 plist，写入 `Contents/Library/LaunchAgents/` 后交给 SMAppService。
/// SMAppService 对相对路径的 `ProgramArguments` 解析不可靠（launchd 显示
/// `inferred program` + `partial import` 并以 EX_CONFIG 拒绝 spawn），
/// 因此注册前把 wrapper 可执行文件的绝对路径写入 plist。
struct SMAppLaunchAgentService: LaunchAgentControlling {
  static let plistName = "com.qiuyuzhou.ShadowsocksX-NG2.agent.plist"

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
    try rewritePlistWithAbsoluteProgramPath()
    try service.register()
  }

  func unregister() throws {
    try service.unregister()
  }

  /// 把 bundle 内 plist 的 ProgramArguments[0] 重写为 wrapper 的绝对路径。
  /// 只在注册前调用；卸载不要求还原。
  private func rewritePlistWithAbsoluteProgramPath() throws {
    let bundle = Bundle.main.bundleURL
    let plistURL = bundle.appendingPathComponent(
      "Contents/Library/LaunchAgents/\(Self.plistName)")
    let agentURL = bundle.appendingPathComponent("Contents/MacOS/ShadowsocksX-NG2Agent")
    guard
      let data = try? Data(contentsOf: plistURL),
      var plist = try? PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any]
    else {
      throw LaunchAgentPlistError.unreadable
    }
    plist["ProgramArguments"] = [agentURL.path]
    let updated = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .xml, options: 0)
    try updated.write(to: plistURL, options: .atomic)
  }
}

enum LaunchAgentPlistError: Error, Equatable {
  case unreadable
}
