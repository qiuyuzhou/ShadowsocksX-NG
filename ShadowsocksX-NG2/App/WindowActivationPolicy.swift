import AppKit
import SwiftUI

/// 随窗激活策略（ADR 0017）：工作区窗口成为 key → regular（Dock 图标与
/// Cmd-Tab 存在），窗口关闭 → accessory，回菜单栏形态。
///
/// 驱动是窗口自身的 NSWindow 生命周期通知，而非 scenePhase——真机实测
/// （2026-09-29）：macOS 上 scenePhase 跟随应用而非窗口，关窗（红点与 ⌘W
/// 同为 performClose）不产生任何 phase 事件，图标摘不掉。`willCloseNotification`
/// 对全部关闭路径必然发布；⌘H 隐藏走 orderOut、不发 willClose，形态自然保持
/// （隐藏≠关窗），unhide 后窗口重回 key 再收敛。
///
/// 目标窗口经内容层锚点视图捕获（`viewDidMoveToWindow` 上交 hosting
/// NSWindow），通知按对象身份过滤——sheet/辅助窗口不是锚点宿主，天然不在
/// 匹配集，无需 window identifier 约定。锚点只在拿到非 nil 窗口时更新：关窗
/// 后 SwiftUI 复用同一 NSWindow（冒烟实测），重开时视 attached 状态或由 key
/// 事件收敛。
/// 策略落点缝：协调器只产出目标策略，真实 NSApp 副作用由注入对象承担
/// （生产=MainApp 组合根；测试=spy，全程 hermetic）。
@MainActor
protocol WindowActivationPolicyApplying: AnyObject {
  func apply(_ policy: NSApplication.ActivationPolicy)
}

@MainActor
final class WindowActivationPolicyCoordinator: ObservableObject {
  private var anchoredWindow: NSWindow?
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
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  /// 锚点视图捕获到宿主窗口时上交（幂等）。窗口已可见才立刻收敛（覆盖不走
  /// key 事件的可见路径）；静默启动预建未呈现的窗口保持 accessory，等打开
  /// 后的 key 事件。
  func anchorDidAttach(to window: NSWindow) {
    guard anchoredWindow !== window else { return }
    anchoredWindow = window
    if window.isVisible {
      applier.apply(.regular)
    }
  }

  @objc private func windowDidBecomeKey(_ notification: Notification) {
    handle(notification, target: .regular)
  }

  @objc private func windowWillClose(_ notification: Notification) {
    handle(notification, target: .accessory)
  }

  private func handle(_ notification: Notification, target: NSApplication.ActivationPolicy) {
    guard let window = notification.object as? NSWindow,
      window === anchoredWindow
    else { return }
    applier.apply(target)
  }
}

/// 挂在 Window scene 内容上的壳修饰器：零尺寸锚点视图捕获宿主 NSWindow，
/// 协调器据其生命周期收敛 app 激活策略。NSApp 侧 applier 由 MainApp 注入
/// （hermetic 判定 `ApplicationDependencies` 是组合根的 private 类型）。
struct WindowActivationPolicy: ViewModifier {
  @StateObject private var coordinator: WindowActivationPolicyCoordinator

  init(applying applier: any WindowActivationPolicyApplying) {
    _coordinator = StateObject(wrappedValue: WindowActivationPolicyCoordinator(applying: applier))
  }

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
