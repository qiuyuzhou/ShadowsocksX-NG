import Foundation

/// 敏感配置文件的原子写盘基线（spec #21 D5）：目录 0700（含自愈）、临时文件
/// 创建即 0600、写全校验后原子替换；任一步失败保留原文件。catalog.json、
/// activation.json 与 #27 的运行时文件共用同一物理安全基线。
enum AtomicFileWriter {
  enum WriteError: Error, Equatable {
    case failure(detail: String)
  }

  /// 把 `data` 原子写入 `fileURL`（含父目录创建与 0700 基线自愈）。
  static func write(_ data: Data, to fileURL: URL) throws {
    let directory = fileURL.deletingLastPathComponent()
    do {
      if !FileManager.default.fileExists(atPath: directory.path) {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      }
      try FileManager.default.setAttributes(
        [.posixPermissions: 0o700], ofItemAtPath: directory.path)
    } catch {
      throw WriteError.failure(detail: String(describing: error))
    }
    let temporaryURL = directory.appendingPathComponent(
      ".\(fileURL.lastPathComponent).tmp-\(UUID().uuidString)")
    if !FileManager.default.createFile(
      atPath: temporaryURL.path,
      contents: data,
      attributes: [.posixPermissions: 0o600]
    ) {
      throw WriteError.failure(detail: "无法创建临时文件 \(temporaryURL.path)")
    }
    do {
      if FileManager.default.fileExists(atPath: fileURL.path) {
        _ = try FileManager.default.replaceItemAt(fileURL, withItemAt: temporaryURL)
      } else {
        try FileManager.default.moveItem(at: temporaryURL, to: fileURL)
      }
    } catch {
      try? FileManager.default.removeItem(at: temporaryURL)
      throw WriteError.failure(detail: String(describing: error))
    }
  }
}
