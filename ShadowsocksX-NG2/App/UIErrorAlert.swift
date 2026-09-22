import Foundation

/// 主窗口共享的错误弹窗呈现状态（UI 持有的窗口状态，issue #41）：目录工作流
/// module 以 typed error 上抛且不生成本地化文案，这里在呈现边缘统一转换。
@MainActor
final class ErrorAlertPresenter: ObservableObject {
  @Published var message: String?

  var isPresented: Bool { message != nil }

  func present(_ error: Error) {
    message = error.presentableMessage
  }

  func present(text: String) {
    message = text
  }

  func dismiss() {
    message = nil
  }
}
