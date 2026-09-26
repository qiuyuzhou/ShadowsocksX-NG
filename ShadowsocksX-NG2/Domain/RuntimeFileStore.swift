import Foundation

/// 运行时文件存取（spec #21 D5，issue #27）：`sslocal-active.json` 是 GUI
/// 写、wrapper 读的跨进程交接契约。写入复用 `AtomicFileWriter` 的物理安全
/// 基线（目录 0700 含自愈、临时文件创建即 0600、写全校验后原子替换）；显式
/// 停止后的清理只做普通 unlink，不承诺安全擦除（D5）。
struct RuntimeFileStore {
  enum PersistenceError: Error, Equatable {
    /// 写入时的文件系统错误。
    case ioFailure(detail: String)
    /// Runtime JSON 写失败后无法恢复此前的 ACL sidecar。
    case rollbackFailed(detail: String)
  }

  let fileURL: URL
  private let fileWriter: (Data, URL) throws -> Void

  init(
    fileURL: URL = RuntimePaths.runtimeFileURL(),
    fileWriter: @escaping (Data, URL) throws -> Void = {
      try AtomicFileWriter.write($0, to: $1)
    }
  ) {
    self.fileURL = fileURL
    self.fileWriter = fileWriter
  }

  /// wrapper pid 文件与契约同目录：GUI 判活与 SIGUSR1 投递依据
  /// （SMAppService 不暴露运行中 agent 的 pid）。
  var pidFileURL: URL {
    fileURL.deletingLastPathComponent().appendingPathComponent("agent.pid")
  }

  var aclFileURL: URL {
    fileURL.deletingLastPathComponent().appendingPathComponent("sslocal-active.acl")
  }

  var runtimeStatusFileURL: URL {
    fileURL.deletingLastPathComponent().appendingPathComponent("agent-runtime-status.json")
  }

  /// 原子写盘；任一步失败保留原文件。
  func write(_ document: SslocalRuntimeDocument) throws {
    let data: Data
    do {
      data = try document.jsonData()
    } catch {
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }

    let previousACLData = try? Data(contentsOf: aclFileURL)
    if let acl = document.aclRuntime {
      guard
        acl.path == aclFileURL.standardizedFileURL.path,
        acl.isWellFormed
      else {
        throw PersistenceError.ioFailure(detail: "ACL sidecar path or digest is invalid")
      }
      do {
        try fileWriter(Data(acl.content.utf8), aclFileURL)
      } catch {
        throw PersistenceError.ioFailure(detail: String(describing: error))
      }
    }

    do {
      try fileWriter(data, fileURL)
    } catch {
      if document.aclRuntime != nil {
        do {
          if let previousACLData {
            try fileWriter(previousACLData, aclFileURL)
          } else {
            try FileManager.default.removeItem(at: aclFileURL)
          }
        } catch {
          throw PersistenceError.rollbackFailed(detail: String(describing: error))
        }
      }
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }
  }

  /// 读取侧判定与 wrapper 同源：缺失、损坏或结构性无效一律 `nil`。
  func loadDocument() -> SslocalRuntimeDocument? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    guard let document = SslocalRuntimeDocument.decodeValidated(data) else { return nil }
    guard let acl = document.aclRuntime else { return document }
    guard
      acl.path == aclFileURL.standardizedFileURL.path,
      let aclData = try? Data(contentsOf: aclFileURL),
      aclData == Data(acl.content.utf8)
    else { return nil }
    return document
  }

  /// 磁盘原始字节，供与派生文档比较以跳过相同内容的写入（幂等）。
  func readData() -> Data? {
    try? Data(contentsOf: fileURL)
  }

  func readRuntimeReceipt() -> RuntimeDeploymentReceipt? {
    guard let data = try? Data(contentsOf: runtimeStatusFileURL) else { return nil }
    return try? JSONDecoder().decode(RuntimeDeploymentReceipt.self, from: data)
  }

  func writeRuntimeReceipt(for document: SslocalRuntimeDocument, processID: Int32) throws {
    guard let digest = document.deploymentSHA256 else {
      throw PersistenceError.ioFailure(detail: "Runtime contract digest is unavailable")
    }
    let receipt = RuntimeDeploymentReceipt(processID: processID, contractSHA256: digest)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    do {
      try AtomicFileWriter.write(try encoder.encode(receipt), to: runtimeStatusFileURL)
    } catch {
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }
  }

  /// 显式停止清理（D2 停止协议末端）：运行时契约文件、wrapper pid 文件与
  /// 原子写残留的临时文件。异常崩溃路径不调用本方法（文件保留供 KeepAlive
  /// 重放，D5）。文件缺失时调用无害。
  func deleteRuntimeFiles() {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: fileURL)
    try? fileManager.removeItem(at: pidFileURL)
    try? fileManager.removeItem(at: aclFileURL)
    try? fileManager.removeItem(at: runtimeStatusFileURL)
    let directory = fileURL.deletingLastPathComponent()
    guard let contents = try? fileManager.contentsOfDirectory(atPath: directory.path) else {
      return
    }
    let temporaryPrefixes = [
      ".\(fileURL.lastPathComponent).tmp-",
      ".\(aclFileURL.lastPathComponent).tmp-",
      ".\(runtimeStatusFileURL.lastPathComponent).tmp-",
    ]
    for name in contents where temporaryPrefixes.contains(where: name.hasPrefix) {
      try? fileManager.removeItem(at: directory.appendingPathComponent(name))
    }
  }
}
