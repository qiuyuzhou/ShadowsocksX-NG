import Foundation

/// 批量导入结果 → 呈现文案（issue #41，story 20/42）：本地化在呈现边缘完成。
/// 失败行以行号点名——不回显行内容（ss:// 行内嵌 base64 密码，story 23）；
/// 原始文本就在输入框/剪贴板里，行号足以定位。
enum ImportOutcomePresentation {
  /// 无失败行返回 `nil`；剪贴板空文本入口由调用方单独呈现。
  static func failureMessage(_ outcome: BatchImportOutcome) -> String? {
    guard !outcome.failures.isEmpty else { return nil }
    let details = outcome.failures.map { failure -> String in
      "第 \(failure.lineIndex + 1) 行：\(failure.reason.presentableMessage)"
    }
    return "已添加 \(outcome.addedCount) 台服务器；以下条目无法解析：\n"
      + details.joined(separator: "\n")
  }
}
