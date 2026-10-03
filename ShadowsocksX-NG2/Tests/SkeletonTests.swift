import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class SkeletonTests: XCTestCase {
  // app bundle 断言按构建产物定位（AppArtifact），不依赖测试宿主进程；守住
  // 的是打包面：bundle id 与旧版区分、菜单栏形态（LSUIElement）。

  func testAppBundleIDIsDistinctFromLegacy() throws {
    let bundle = try XCTUnwrap(Bundle(url: AppArtifact.bundleURL))
    XCTAssertEqual(bundle.bundleIdentifier, "com.qiuyuzhou.ShadowsocksX-NG2")
    XCTAssertNotEqual(bundle.bundleIdentifier, "com.qiuyuzhou.ShadowsocksX-NG")
  }

  func testAppIsMenuBarAgent() throws {
    let bundle = try XCTUnwrap(Bundle(url: AppArtifact.bundleURL))
    XCTAssertEqual(bundle.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
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
      UI 源文件不得引用代理控制器、目录工作流实现协作者或原始目录/凭据存储类型；
      经 CatalogWorkflow/ProxyControlWorkflow 的 UI-facing interface 表达
      （issue #49；控制器依赖由主窗口壳与服务器分区清零后固化为守卫）：
      \(violations.joined(separator: "\n"))
      """)
  }

  // MARK: - 扫描范围与禁令表

  private static let testTargetRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent()

  /// 豁免文件：组合根（生产 adapter 唯一装配点）与运行时/系统适配器（合法
  /// 接触原始目录与凭据类型）。
  private static let exemptedFiles: Set<String> = [
    "MainApp.swift",
    "CatalogCommitCoordinator.swift",
    // 运行时 facts 投影：适配器侧把控制器状态映射为 typed facts，非 UI 表面。
    "ProxyRuntimeFacts.swift",
    "SystemProxyHelperService.swift",
    "LaunchAgentService.swift",
    "LoginAtLoginService.swift",
    "FirewallStatusChecker.swift",
  ]

  /// 豁免前缀：控制器家族（本体与按命令面/收敛脊柱/系统代理门禁等分的各文件）
  /// 同属运行时适配器，合法接触代理控制器类型。
  private static let exemptedFilePrefixes: Set<String> = [
    "ProxyRuntimeController"
  ]

  /// 豁免目录：workflow module 实现（含被测的目录工作流自身）。
  private static let exemptedDirectories: Set<String> = [
    "CatalogWorkflow", "ProxyControlWorkflow", "SettingsWorkflow", "DiagnosticsWorkflow",
  ]

  /// 禁令：实现协作者类型、原始目录/凭据存储类型与 workflow 内部成员缝。
  private static let forbiddenPatterns = makeForbiddenPatterns()

  private static func makeForbiddenPatterns() -> [(label: String, regex: NSRegularExpression)] {
    let typeTokens = [
      "ProxyRuntimeController",
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
      guard
        name.hasSuffix(".swift"),
        !exemptedFiles.contains(name),
        !exemptedFilePrefixes.contains(where: { name.hasPrefix($0) })
      else { continue }
      let relativePath = url.path.replacingOccurrences(of: directory.path + "/", with: "")
      guard !exemptedDirectories.contains(where: { relativePath.hasPrefix("\($0)/") })
      else { continue }
      result.append(url)
    }
    return result
  }
}
