import AppKit
import SwiftUI

/// All explicitly anchored application windows share one coordinator. Sheets and
/// unrelated windows do not participate. Hiding does not count as closing.
@MainActor
protocol WindowActivationPolicyApplying: AnyObject {
  func apply(_ policy: NSApplication.ActivationPolicy)
}

@MainActor
final class WindowActivationPolicyCoordinator: ObservableObject {
  private let anchoredWindows = NSHashTable<NSWindow>.weakObjects()
  private var openWindows: Set<ObjectIdentifier> = []
  private let applier: any WindowActivationPolicyApplying

  /// `applier` 注入以便 hermetic 单测；生产实现里单测 host 不触碰真实 NSApp。
  init(applying applier: any WindowActivationPolicyApplying) {
    self.applier = applier
    let center = NotificationCenter.default
    center.addObserver(
      self, selector: #selector(windowDidBecomeKey(_:)),
      name: NSWindow.didBecomeKeyNotification, object: nil)
    center.addObserver(
      self, selector: #selector(windowWillClose(_:)),
      name: NSWindow.willCloseNotification, object: nil)
    center.addObserver(
      self, selector: #selector(windowVisibilityChanged(_:)),
      name: NSWindow.didChangeOcclusionStateNotification, object: nil)
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  /// 锚点视图捕获到宿主窗口时上交（幂等）。窗口已可见才立刻收敛（覆盖不走
  /// key 事件的可见路径）；静默启动预建未呈现的窗口保持 accessory，等打开
  /// 后的 key 事件。
  func anchorDidAttach(to window: NSWindow) {
    anchoredWindows.add(window)
    if window.isVisible {
      openWindows.insert(ObjectIdentifier(window))
      applier.apply(.regular)
    }
  }

  @objc private func windowDidBecomeKey(_ notification: Notification) {
    guard let window = trackedWindow(in: notification) else { return }
    openWindows.insert(ObjectIdentifier(window))
    applier.apply(.regular)
  }

  @objc private func windowWillClose(_ notification: Notification) {
    guard let window = trackedWindow(in: notification) else { return }
    // A background window can be presented without ever becoming key. Include
    // visible siblings even if their initial visibility notification was missed.
    for sibling in anchoredWindows.allObjects where sibling !== window && sibling.isVisible {
      openWindows.insert(ObjectIdentifier(sibling))
    }
    openWindows.remove(ObjectIdentifier(window))
    if openWindows.isEmpty { applier.apply(.accessory) }
  }

  @objc private func windowVisibilityChanged(_ notification: Notification) {
    guard let window = trackedWindow(in: notification), window.isVisible else { return }
    let inserted = openWindows.insert(ObjectIdentifier(window)).inserted
    if inserted { applier.apply(.regular) }
  }

  private func trackedWindow(in notification: Notification) -> NSWindow? {
    guard let window = notification.object as? NSWindow, anchoredWindows.contains(window)
    else { return nil }
    return window
  }
}

/// 挂在 Window scene 内容上的壳修饰器：零尺寸锚点视图捕获宿主 NSWindow，
/// 协调器据其生命周期收敛 app 激活策略。NSApp 侧 applier 由 MainApp 注入
/// （hermetic 判定 `ApplicationDependencies` 是组合根的 private 类型）。
struct WindowActivationPolicy: ViewModifier {
  @ObservedObject var coordinator: WindowActivationPolicyCoordinator

  func body(content: Content) -> some View {
    content.background(WindowActivationAnchor(onAttach: coordinator.anchorDidAttach))
  }
}

/// 锚点视图：随内容装进宿主窗口，`viewDidMoveToWindow` 上交宿主。
private struct WindowActivationAnchor: NSViewRepresentable {
  let onAttach: (NSWindow) -> Void

  func makeNSView(context: Context) -> AnchorView {
    AnchorView(onAttach: onAttach)
  }

  func updateNSView(_ nsView: AnchorView, context: Context) {}

  final class AnchorView: NSView {
    private let onAttach: (NSWindow) -> Void

    init(onAttach: @escaping (NSWindow) -> Void) {
      self.onAttach = onAttach
      super.init(frame: .zero)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
      fatalError("NSView 不走 storyboard 初始化")
    }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      // 关窗时 SwiftUI 可能置 nil（复用窗口语义下内容也可能保留）；nil 不回写，
      // 已捕获引用留给 willClose 匹配，重开由重新 attach 或 key 事件覆盖。
      if let window {
        onAttach(window)
      }
    }
  }
}
