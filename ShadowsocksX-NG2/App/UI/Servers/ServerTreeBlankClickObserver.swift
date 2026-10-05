import SwiftUI

/// List 没有空白点击回调；用原生表格的行命中判断，不拦截行选择、按钮或滚动条。
struct ServerTreeBlankClickObserver: NSViewRepresentable {
  let onBlankClick: () -> Void

  func makeNSView(context: Context) -> ObserverView {
    let view = ObserverView()
    view.onBlankClick = onBlankClick
    return view
  }

  func updateNSView(_ view: ObserverView, context: Context) {
    view.onBlankClick = onBlankClick
  }

  static func dismantleNSView(_ view: ObserverView, coordinator: ()) {
    view.stopObserving()
  }

  final class ObserverView: NSView {
    var onBlankClick: (() -> Void)?
    private var monitor: Any?

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func viewDidMoveToWindow() {
      super.viewDidMoveToWindow()
      stopObserving()
      guard window != nil else { return }
      monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
        self?.handleClick(event)
        return event
      }
    }

    func stopObserving() {
      if let monitor { NSEvent.removeMonitor(monitor) }
      monitor = nil
    }

    private func handleClick(_ event: NSEvent) {
      guard let window, event.window === window,
        visibleRect.contains(convert(event.locationInWindow, from: nil))
      else { return }
      // 背景探针与 List 的原生滚动视图是兄弟；向上寻找共同容器，
      // 只接受点击点处的表格，排除滚动条和其他列表。
      var container = superview
      while let current = container {
        if let table = table(at: event.locationInWindow, in: current) {
          // 覆盖式滚动条可能落在表格几何范围内，实际命中必须属于表格。
          guard let content = window.contentView else { return }
          let hitPoint =
            content.superview?.convert(event.locationInWindow, from: nil)
            ?? event.locationInWindow
          var hit = content.hitTest(hitPoint)
          while let view = hit, view !== table { hit = view.superview }
          guard hit === table else { return }
          let point = table.convert(event.locationInWindow, from: nil)
          if table.row(at: point) == -1 { onBlankClick?() }
          return
        }
        container = current.superview
      }
    }

    private func table(at point: NSPoint, in view: NSView) -> NSTableView? {
      if let table = view as? NSTableView,
        table.visibleRect.contains(table.convert(point, from: nil))
      {
        return table
      }
      for child in view.subviews {
        if let table = table(at: point, in: child) { return table }
      }
      return nil
    }
  }
}
