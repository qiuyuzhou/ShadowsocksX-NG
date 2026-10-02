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
      [.home, .servers, .subscriptions, .rules, .settings, .diagnostics])
  }

  func testNavigateChangesDestinationOnly() {
    let route = WorkspaceRoute()

    route.navigate(to: .servers)

    XCTAssertEqual(route.destination, .servers)
  }

  /// 开窗落点纪律（ADR 0016，scene 方式）：主窗口是 SwiftUI `Window` scene，
  /// 主窗口重开只由状态菜单发起，规则页只可打开转换报告；启动呈现由
  /// 场景 defaultLaunchBehavior 负责。workspace id 保持在 route 中定义。
  func testWindowOpeningStaysInSanctionedSurfaces() throws {
    let appDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("App", isDirectory: true)
    let openWindowAllowed = Set(["ProxyStatusMenu.swift", "RulesView.swift"])
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
      if name == "RulesView.swift" {
        let calls = source.components(separatedBy: .newlines).filter { $0.contains("openWindow(") }
        XCTAssertTrue(
          calls.allSatisfy { $0.contains("openWindow(id: RulesReportView.sceneID)") },
          "规则页只能打开转换报告窗口")
      }
      if !openWindowAllowed.contains(name), source.contains("openWindow(") {
        openWindowViolations.append(name)
      }
      if !sceneIDLiteralAllowed.contains(name), source.contains(#""workspace""#) {
        sceneIDViolations.append(name)
      }
    }

    XCTAssertTrue(
      openWindowViolations.isEmpty,
      "openWindow 调用只允许在状态菜单和规则报告入口：\(openWindowViolations)")
    XCTAssertTrue(
      sceneIDViolations.isEmpty,
      "scene id 字面量只允许定义在 WorkspaceRoute：\(sceneIDViolations)")
  }
}
