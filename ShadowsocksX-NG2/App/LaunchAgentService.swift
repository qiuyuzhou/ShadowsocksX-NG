import Foundation
import ServiceManagement

/// LaunchAgent 管理缝（spec #21 D2）：控制器经此协议启停 agent，单元测试以
/// fake 替换（真实注册会改动用户登录项，不进单测）。
protocol LaunchAgentControlling {
  var status: LaunchAgentStatus { get }
  func register() throws
  func unregister() throws
}

/// 生产实现。用 `launchctl bootstrap` 注册 `~/Library/LaunchAgents/` 下带
/// 绝对路径的 plist（SMAppService 对相对 ProgramArguments 的解析在
/// DerivedData 等非 /Applications 路径下不可靠，launchd 报 `inferred
/// program` + `partial import` 并以 EX_CONFIG 拒绝 spawn）。SMAppService
/// 仅用于读取 BTM 批准状态；批准流仍走系统设置 → 登录项。
struct SMAppLaunchAgentService: LaunchAgentControlling {
  static let label = "com.qiuyuzhou.ShadowsocksX-NG2.agent"

  private let service = SMAppService.agent(
    plistName: "com.qiuyuzhou.ShadowsocksX-NG2.agent.plist")

  var status: LaunchAgentStatus {
    if isLoadedInLaunchd { return .registered }
    switch service.status {
    case .requiresApproval:
      return .requiresApproval
    case .enabled:
      return .registered
    default:
      return .notRegistered
    }
  }

  func register() throws {
    try writeUserPlist()
    try runLaunchctl(["bootstrap", "gui/\(getuid())", userPlistURL.path])
  }

  func unregister() throws {
    _ = try? runLaunchctl(["bootout", "gui/\(getuid())/\(Self.label)"])
    try? FileManager.default.removeItem(at: userPlistURL)
  }

  // MARK: - Implementation

  private var userPlistURL: URL {
    FileManager.default.homeDirectoryForCurrentUser
      .appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
  }

  private var agentBinaryURL: URL {
    Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ShadowsocksX-NG2Agent")
  }

  private var isLoadedInLaunchd: Bool {
    (try? runLaunchctl(["print", "gui/\(getuid())/\(Self.label)"])) != nil
  }

  private func writeUserPlist() throws {
    let plist: [String: Any] = [
      "Label": Self.label,
      "ProgramArguments": [agentBinaryURL.path],
      "KeepAlive": ["SuccessfulExit": false],
      "ThrottleInterval": 2,
    ]
    let data = try PropertyListSerialization.data(
      fromPropertyList: plist, format: .xml, options: 0)
    try FileManager.default.createDirectory(
      at: userPlistURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    try data.write(to: userPlistURL, options: .atomic)
  }

  @discardableResult
  private func runLaunchctl(_ arguments: [String]) throws -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = arguments
    let stderr = Pipe()
    process.standardError = stderr
    try process.run()
    process.waitUntilExit()
    let errorOutput =
      String(
        data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard process.terminationStatus == 0 else {
      throw LaunchAgentRegistrationError.launchctlFailed(errorOutput)
    }
    return errorOutput
  }
}

enum LaunchAgentRegistrationError: Error, Equatable {
  case launchctlFailed(String)
}
