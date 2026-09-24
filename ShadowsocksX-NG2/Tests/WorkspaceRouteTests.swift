import Foundation
import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class WorkspaceRouteTests: XCTestCase {
  private final class RecordingWindowOpening: WorkspaceWindowOpening {
    var openCount = 0
    var destinationAtOpen: WorkspaceDestination?
    var onOpen: (() -> Void)?

    func ensureWorkspaceVisible() {
      openCount += 1
      onOpen?()
    }
  }

  func testFreshRouteStartsAtHomeWithoutPersistedState() {
    XCTAssertEqual(WorkspaceRoute(opensWorkspaceAtLaunch: true).destination, .home)
  }

  func testDestinationVocabularyIsFiniteAndStable() {
    XCTAssertEqual(
      WorkspaceDestination.allCases,
      [.home, .servers, .subscriptions, .settings, .diagnostics])
  }

  func testRegularLaunchPresentsWorkspaceAtHome() {
    let route = WorkspaceRoute(opensWorkspaceAtLaunch: true)
    let opening = RecordingWindowOpening()
    opening.onOpen = { opening.destinationAtOpen = route.destination }

    route.handle(.launch, using: opening)

    XCTAssertEqual(route.destination, .home)
    XCTAssertEqual(opening.openCount, 1)
    XCTAssertEqual(opening.destinationAtOpen, .home)
  }

  func testLoginItemLaunchStaysSilent() {
    let route = WorkspaceRoute(opensWorkspaceAtLaunch: false)
    let opening = RecordingWindowOpening()

    route.handle(.launch, using: opening)

    XCTAssertEqual(route.destination, .home)
    XCTAssertEqual(opening.openCount, 0)
  }

  func testSilentLaunchStillAllowsExplicitPresentation() {
    let route = WorkspaceRoute(opensWorkspaceAtLaunch: false)
    let opening = RecordingWindowOpening()

    route.handle(.launch, using: opening)
    route.handle(.present(destination: .settings), using: opening)

    XCTAssertEqual(route.destination, .settings)
    XCTAssertEqual(opening.openCount, 1)
  }

  func testLaunchPolicyIsAppliedOnlyOnce() {
    let route = WorkspaceRoute(opensWorkspaceAtLaunch: true)
    let opening = RecordingWindowOpening()

    route.handle(.launch, using: opening)
    route.handle(.launch, using: opening)

    XCTAssertEqual(opening.openCount, 1)
  }

  func testDelayedLaunchPolicyDoesNotOverwriteExplicitDestination() {
    let route = WorkspaceRoute(opensWorkspaceAtLaunch: true)
    let opening = RecordingWindowOpening()
    opening.onOpen = { opening.destinationAtOpen = route.destination }

    route.handle(.present(destination: .settings), using: opening)
    route.handle(.launch, using: opening)

    XCTAssertEqual(route.destination, .settings)
    XCTAssertEqual(opening.openCount, 2)
    XCTAssertEqual(opening.destinationAtOpen, .settings)
  }

  func testExplicitSettingsPresentationSelectsBeforeOpeningWorkspace() {
    let route = WorkspaceRoute(opensWorkspaceAtLaunch: true)
    let opening = RecordingWindowOpening()
    opening.onOpen = { opening.destinationAtOpen = route.destination }

    route.handle(.present(destination: .settings), using: opening)

    XCTAssertEqual(route.destination, .settings)
    XCTAssertEqual(opening.openCount, 1)
    XCTAssertEqual(opening.destinationAtOpen, .settings)
  }

  func testInWorkspaceNavigationChangesDestinationWithoutOpeningWindow() {
    let route = WorkspaceRoute(opensWorkspaceAtLaunch: true)
    let opening = RecordingWindowOpening()

    route.handle(.navigate(destination: .servers), using: opening)

    XCTAssertEqual(route.destination, .servers)
    XCTAssertEqual(opening.openCount, 0)
  }

  func testExplicitHomePresentationSelectsHomeBeforeOpeningWorkspace() {
    let route = WorkspaceRoute(opensWorkspaceAtLaunch: true)
    let opening = RecordingWindowOpening()
    opening.onOpen = { opening.destinationAtOpen = route.destination }
    route.navigate(to: .diagnostics)

    route.handle(.present(destination: .home), using: opening)

    XCTAssertEqual(route.destination, .home)
    XCTAssertEqual(opening.openCount, 1)
    XCTAssertEqual(opening.destinationAtOpen, .home)
  }

  func testPassiveReopenRetainsCurrentDestination() {
    let route = WorkspaceRoute(opensWorkspaceAtLaunch: true)
    let opening = RecordingWindowOpening()
    opening.onOpen = { opening.destinationAtOpen = route.destination }
    route.handle(.navigate(destination: .diagnostics), using: opening)

    route.handle(.reopen, using: opening)

    XCTAssertEqual(route.destination, .diagnostics)
    XCTAssertEqual(opening.openCount, 1)
    XCTAssertEqual(opening.destinationAtOpen, .diagnostics)
  }

  func testSceneOpeningEffectsRemainInCompositionRootOrFocusedAdapter() throws {
    let appDirectory = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .appendingPathComponent("App", isDirectory: true)
    let allowedFiles = Set(["MainApp.swift", "WorkspaceWindowOpeningAdapter.swift"])
    let fileManager = FileManager.default
    let urls = try XCTUnwrap(
      fileManager.enumerator(
        at: appDirectory,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
      )?.compactMap { $0 as? URL }
        .filter { $0.pathExtension == "swift" })

    let violations = urls.compactMap { url -> String? in
      guard !allowedFiles.contains(url.lastPathComponent),
        let source = try? String(contentsOf: url, encoding: .utf8)
      else { return nil }
      guard
        source.contains("openWindow(id:") || source.contains("id: \"main\"")
          || source.contains("id: \"settings\"")
      else { return nil }
      return url.lastPathComponent
    }

    XCTAssertTrue(
      violations.isEmpty,
      "scene ID 与开窗 effect 只能位于组合根或专用 adapter：\(violations)")
  }
}
