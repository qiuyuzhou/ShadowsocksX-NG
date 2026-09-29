import AppKit
import XCTest

@testable import ShadowsocksX_NG2

/// 随窗激活策略协调器（ADR 0017）：窗口成为 key → regular，willClose →
/// accessory，按锚定窗口的对象身份过滤（sheet/辅助窗口不在匹配集）。通知用
/// 手工 post 驱动、applier 用 spy 注入，全程 hermetic，不触碰真实 NSApp 策略
/// 与 WindowServer 呈现。
@MainActor
final class WindowActivationPolicyTests: XCTestCase {
  private var spy: SpyApplier!
  private var coordinator: WindowActivationPolicyCoordinator!
  private var window: NSWindow!
  private var foreignWindow: NSWindow!

  override func setUpWithError() throws {
    try super.setUpWithError()
    spy = SpyApplier()
    coordinator = WindowActivationPolicyCoordinator(applying: spy)
    // 离屏裸窗口仅作通知对象身份：不呈现、不抢 key，创建本身不触碰
    // WindowServer 的窗口呈现。
    window = Self.makeOffscreenWindow()
    foreignWindow = Self.makeOffscreenWindow()
    coordinator.anchorDidAttach(to: window)
  }

  override func tearDownWithError() throws {
    window = nil
    foreignWindow = nil
    try super.tearDownWithError()
  }

  /// 策略落点 spy（ADR 0017）：只记录目标策略，不触碰真实 NSApp。
  @MainActor
  private final class SpyApplier: WindowActivationPolicyApplying {
    private(set) var applied: [NSApplication.ActivationPolicy] = []

    func apply(_ policy: NSApplication.ActivationPolicy) {
      applied.append(policy)
    }
  }

  private static func makeOffscreenWindow() -> NSWindow {
    NSWindow(
      contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
      styleMask: [.titled],
      backing: .buffered,
      defer: false)
  }

  private func post(_ name: Notification.Name, on target: NSWindow) {
    NotificationCenter.default.post(name: name, object: target)
  }

  // MARK: 随窗收敛

  func testAttachToNotYetVisibleWindowAppliesNothing() {
    XCTAssertTrue(
      spy.applied.isEmpty,
      "静默启动预建未呈现的窗口不得触发 regular：启动应停留在 accessory")
  }

  func testDidBecomeKeyAppliesRegular() {
    post(NSWindow.didBecomeKeyNotification, on: window)

    XCTAssertEqual(spy.applied, [.regular])
  }

  func testWillCloseAppliesAccessory() {
    post(NSWindow.willCloseNotification, on: window)

    XCTAssertEqual(spy.applied, [.accessory])
  }

  // MARK: 身份过滤

  func testForeignWindowNotificationsAreIgnored() {
    post(NSWindow.didBecomeKeyNotification, on: foreignWindow)
    post(NSWindow.willCloseNotification, on: foreignWindow)

    XCTAssertTrue(spy.applied.isEmpty, "非锚定窗口（sheet/辅助窗口）不得驱动策略")
  }

  func testAnchorReplacementRetargetsFiltering() {
    coordinator.anchorDidAttach(to: foreignWindow)

    post(NSWindow.willCloseNotification, on: window)
    XCTAssertTrue(spy.applied.isEmpty, "旧窗口不再匹配")

    post(NSWindow.willCloseNotification, on: foreignWindow)
    XCTAssertEqual(spy.applied, [.accessory])
  }
}
