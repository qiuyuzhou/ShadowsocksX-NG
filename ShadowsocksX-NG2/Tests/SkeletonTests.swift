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
/// 协作者或原始目录/凭据存储类型。
///
/// 扫描范围由目录正面圈定：只扫 `App/UI/`（视图层）。分层因此是目录声明而非
/// 豁免登记——把文件移出 `UI/` 是显式的架构动作；组合根放 `App/Composition/`、
/// 运行时与系统适配器放 `App/Application/`、平台效应 seam 放
/// `App/PlatformEffects/`，天然落在扫描范围之外，新增时无需登记豁免。
/// 规则只点名实现缝，不锁定实现内部的文件划分或私有 helper。
final class CatalogWorkflowArchitectureTests: XCTestCase {
  func testUISourceFilesDoNotReferenceCatalogWorkflowImplementation() throws {
    let uiDirectory = Self.testTargetRoot.appendingPathComponent("App/UI")
    let uiFiles = try Self.swiftSourceFiles(in: uiDirectory)
    XCTAssertFalse(uiFiles.isEmpty, "UI 源文件集合不应为空（App/UI 目录缺失？）")

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

  /// 禁令：实现协作者类型、原始目录/凭据存储类型与 workflow 内部成员缝。
  private static let forbiddenPatterns = makeForbiddenPatterns()

  private static func makeForbiddenPatterns() -> [(label: String, regex: NSRegularExpression)] {
    let typeTokens = [
      "ProxyRuntimeController",
      "CatalogWorkflowDependencies", "CatalogCommitCoordinator", "CatalogFileStore",
      "ConfigurationCatalog", "CatalogEntry", "CommittedCatalogSnapshot",
      "CredentialStoring", "KeychainCredentialStore", "CredentialWriteJournal",
      "CredentialReference", "PluginExecutableResolving", "BundleManagedPluginProvider",
      "SubscriptionFetching", "HTTPSSubscriptionFetcher", "SubscriptionRecord",
      "LegacyImportService", "LegacySnapshot", "Activating", "ServerFields",
    ]
    // workflow 内部成员缝（不作为可访问属性/方法暴露给 UI）。
    let memberTokens = [
      "\\.dependencies\\b", "\\bfileStore\\b", "discoveredLegacySnapshot",
      "republishCommittedState", "commitSubscriptionDocument", "publishLegacyImportState",
      "setRefreshInFlight", "setSubscriptionRefreshFailure",
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

  /// 视图层源文件 = `App/UI/` 下全部 Swift 文件（递归含各子视图目录）。
  private static func swiftSourceFiles(in directory: URL) throws -> [URL] {
    guard
      let enumerator = FileManager.default.enumerator(
        at: directory, includingPropertiesForKeys: nil)
    else {
      XCTFail("无法枚举 UI 源码目录：\(directory.path)")
      return []
    }
    return enumerator.compactMap { item in
      guard let url = item as? URL, url.pathExtension == "swift" else { return nil }
      return url
    }
  }
}
