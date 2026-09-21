import AppKit

/// NSWorkspace 实现的 Legacy app 检测缝（issue #37）：NG2 与 Legacy 共享
/// bundle id（D1 继承），「正在运行的旧版 app」= 该 bundle id 下除自身进程外
/// 的任何进程。NSRunningApplication 要求主线程，非主线程调用同步派发——
/// 调用方（交接检测在后台任务）挂起等待而非阻塞主线程，无死锁。
final class WorkspaceLegacyAppController: LegacyAppControlling {
  static let legacyBundleIdentifier = "com.qiuyuzhou.ShadowsocksX-NG"

  func isRunning() -> Bool {
    MainActor.runUnsafelyIfNeeded { legacyApplication() != nil }
  }

  func isInstalled() -> Bool {
    Self.bundleURLs.contains { FileManager.default.fileExists(atPath: $0.path) }
  }

  func requestGracefulQuit() -> Bool {
    MainActor.runUnsafelyIfNeeded { legacyApplication()?.terminate() ?? false }
  }

  /// 常见安装位置（Legacy LaunchHelper 自身也按这些位置找主 app）。
  private static let bundleURLs: [URL] = [
    URL(fileURLWithPath: "/Applications/ShadowsocksX-NG.app"),
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Applications/ShadowsocksX-NG.app", isDirectory: true),
  ]

  private func legacyApplication() -> NSRunningApplication? {
    NSRunningApplication
      .runningApplications(withBundleIdentifier: Self.legacyBundleIdentifier)
      .first { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
  }
}

extension MainActor {
  /// 供非主线程上下文同步执行 AppKit 调用的小帮手；主线程上直接执行。
  fileprivate static func runUnsafelyIfNeeded<T>(_ body: @MainActor () -> T) -> T {
    if Thread.isMainThread {
      // 主线程上已满足隔离要求，直接执行（MainActor.assumeIsolated）。
      return MainActor.assumeIsolated(body)
    }
    return DispatchQueue.main.sync {
      MainActor.assumeIsolated(body)
    }
  }
}
