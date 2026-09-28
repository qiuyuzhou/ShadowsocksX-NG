import Foundation
import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class WorkspaceRouteTests: XCTestCase {
  func testFreshRouteStartsAtHomeWithoutPersistedState() {
    XCTAssertEqual(WorkspaceRoute().destination, .home)
  }

  func testDestinationVocabularyIsFiniteAndStable() {
    XCTAssertEqual(
      WorkspaceDestination.allCases,
      [.home, .servers, .subscriptions, .settings, .diagnostics])
  }

  func testNavigateChangesDestinationOnly() {
    let route = WorkspaceRoute()

    route.navigate(to: .servers)

    XCTAssertEqual(route.destination, .servers)
  }

  /// 开窗落点纪律（ADR 0016，scene 方式）：主窗口是 SwiftUI `Window` scene，
  /// `openWindow` 调用只允许出现在状态菜单（关窗后的重开入口；启动呈现由
  /// 场景 defaultLaunchBehavior 负责）；scene id 字面量只允许定义在 route
  /// （单点词汇），组合根以常量声明 scene。防视图任意开窗与 scene id 散落
  /// 回归 AppKit 直控。
  func testWindowOpeningStaysInSanctionedSurfaces() throws {
    let appDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("App", isDirectory: true)
    let openWindowAllowed = Set(["ProxyStatusMenu.swift"])
    let sceneIDLiteralAllowed = Set(["WorkspaceRoute.swift"])
    let fileManager = FileManager.default
    let urls = try XCTUnwrap(
      fileManager.enumerator(
        at: appDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )?.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" })

    var openWindowViolations: [String] = []
    var sceneIDViolations: [String] = []
    for url in urls {
      guard let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
      let name = url.lastPathComponent
      if !openWindowAllowed.contains(name), source.contains("openWindow(") {
        openWindowViolations.append(name)
      }
      if !sceneIDLiteralAllowed.contains(name), source.contains(#""workspace""#) {
        sceneIDViolations.append(name)
      }
    }

    XCTAssertTrue(
      openWindowViolations.isEmpty,
      "openWindow 调用只允许在状态菜单：\(openWindowViolations)")
    XCTAssertTrue(
      sceneIDViolations.isEmpty,
      "scene id 字面量只允许定义在 WorkspaceRoute：\(sceneIDViolations)")
  }
}
