import XCTest

@testable import ShadowsocksX_NG2

final class SkeletonTests: XCTestCase {
  // 以下两个 Bundle.main 断言依赖测试包以 app 为 TEST_HOST 注入（target dependency）；
  // 若移除该依赖，Bundle.main 不再是 app bundle，断言会失效。

  func testMenuBarAppDoesNotTerminateAfterLastWindowClosed() {
    let delegate = AppDelegate()
    XCTAssertFalse(delegate.applicationShouldTerminateAfterLastWindowClosed(.shared))
  }

  func testAppBundleIDIsDistinctFromLegacy() {
    XCTAssertEqual(Bundle.main.bundleIdentifier, "com.qiuyuzhou.ShadowsocksX-NG2")
    XCTAssertNotEqual(Bundle.main.bundleIdentifier, "com.qiuyuzhou.ShadowsocksX-NG")
  }

  func testAppIsMenuBarAgent() {
    XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
  }
}

/// 架构 deletion check（issue #49）：UI 源文件不得引用目录工作流的实现
/// 协作者或原始目录/凭据存储类型。组合根（MainApp）与各 workflow module
/// 目录豁免；新增视图文件自动纳入扫描，新增运行时/系统适配器需显式登记
/// 豁免名单。规则只点名实现缝，不锁定实现内部的文件划分或私有 helper。
final class CatalogWorkflowArchitectureTests: XCTestCase {
  func testUISourceFilesDoNotReferenceCatalogWorkflowImplementation() throws {
    let appDirectory = Self.testTargetRoot.appendingPathComponent("App")
    let uiFiles = try Self.uiSourceFiles(in: appDirectory)
    XCTAssertFalse(uiFiles.isEmpty, "UI 源文件集合不应为空（App 目录缺失？）")

    var violations: [String] = []
    for file in uiFiles {
      let content = try String(contentsOf: file, encoding: .utf8)
      for (index, line) in content.components(separatedBy: .newlines).enumerated() {
        for pattern in Self.forbiddenPatterns
        where pattern.regex.firstMatch(
          in: line, range: NSRange(line.startIndex..., in: line)) != nil
        {
          violations.append("\(file.lastPathComponent):\(index + 1) → \(pattern.label)")
        }
      }
    }
    XCTAssertTrue(
      violations.isEmpty,
      """
      UI 源文件不得引用目录工作流实现协作者或原始目录/凭据存储类型；
      经 CatalogWorkflow 的 UI-facing interface 表达（issue #49）：
      \(violations.joined(separator: "\n"))
      """)
  }

  // MARK: - 扫描范围与禁令表

  private static let testTargetRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

  /// 豁免文件：组合根（生产 adapter 唯一装配点）、应用生命周期与运行时/
  /// 系统适配器（合法接触原始目录与凭据类型）。
  private static let exemptedFiles: Set<String> = [
    "MainApp.swift",
    "AppDelegate.swift",
    "CatalogCommitCoordinator.swift",
    "ProxyRuntimeController.swift",
    // 控制器按命令面/设置与目录同步/系统代理门禁/事实投影分文件（同属运行时适配器）。
    "ProxyRuntimeController+Commands.swift",
    "ProxyRuntimeController+SettingsSync.swift",
    "ProxyRuntimeController+SystemProxyGate.swift",
    "ProxyRuntimeController+Facts.swift",
    "SystemConfigurationProxyController.swift",
    "LaunchAgentService.swift",
    "LoginAtLoginService.swift",
    "FirewallStatusChecker.swift",
    "PACHealthProbe.swift",
  ]

  /// 豁免目录：workflow module 实现（含被测的目录工作流自身）。
  private static let exemptedDirectories: Set<String> = [
    "CatalogWorkflow", "ProxyControlWorkflow", "SettingsWorkflow", "DiagnosticsWorkflow",
  ]

  /// 禁令：实现协作者类型、原始目录/凭据存储类型与 workflow 内部成员缝。
  private static let forbiddenPatterns = makeForbiddenPatterns()

  private static func makeForbiddenPatterns() -> [(label: String, regex: NSRegularExpression)] {
    let typeTokens = [
      "CatalogWorkflowDependencies", "CatalogCommitCoordinator", "CatalogFileStore",
      "ConfigurationCatalog", "CatalogEntry", "CommittedCatalogSnapshot",
      "CredentialStoring", "KeychainCredentialStore", "CredentialWriteJournal",
      "CredentialReference", "ManagedPluginProviding", "BundleManagedPluginProvider",
      "SubscriptionFetching", "HTTPSSubscriptionFetcher", "SubscriptionRecord",
      "LegacyImportService", "LegacySnapshot", "Activating", "ServerFields",
    ]
    // workflow 内部成员缝（不作为可访问属性/方法暴露给 UI）。
    let memberTokens = [
      "\\.dependencies\\b", "\\bfileStore\\b", "discoveredLegacySnapshot",
      "republishCommittedState", "commitSubscriptionDocument", "publishLegacyImportState",
      "publishLegacyImportReport", "setRefreshInFlight", "setSubscriptionRefreshFailure",
      "subscriptionSummaries", "credentialRefs",
    ]
    return (typeTokens + memberTokens).map { token in
      do {
        return (label: token, regex: try NSRegularExpression(pattern: token))
      } catch {
        preconditionFailure("禁令正则编译失败：\(token)")
      }
    }
  }

  /// UI 源文件 = App 下全部 Swift 文件，除豁免名单与 workflow module 目录。
  private static func uiSourceFiles(in directory: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil)
    else {
      XCTFail("无法枚举 App 源码目录：\(directory.path)")
      return []
    }
    var result: [URL] = []
    for case let url as URL in enumerator {
      let name = url.lastPathComponent
      guard name.hasSuffix(".swift"), !exemptedFiles.contains(name) else { continue }
      let relativePath = url.path.replacingOccurrences(of: directory.path + "/", with: "")
      guard !exemptedDirectories.contains(where: { relativePath.hasPrefix("\($0)/") })
      else { continue }
      result.append(url)
    }
    return result
  }
}
