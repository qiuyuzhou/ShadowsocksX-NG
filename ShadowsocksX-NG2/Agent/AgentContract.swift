import Foundation

// MARK: - 契约与子进程

enum ContractLoad {
  case missing
  case invalid
  case loaded(SslocalRuntimeDocument)
}

func loadContract() -> ContractLoad {
  guard let data = try? Data(contentsOf: contractURL) else { return .missing }
  guard let document = SslocalRuntimeDocument.decodeValidated(data) else { return .invalid }
  if let acl = document.aclRuntime {
    guard
      document.aclFilePath == aclFileURL.standardizedFileURL.path,
      acl.path == aclFileURL.standardizedFileURL.path,
      let aclData = try? Data(contentsOf: aclFileURL),
      aclData == Data(acl.content.utf8)
    else { return .invalid }
  }
  return .loaded(document)
}

func writeRuntimeReceipt(for document: SslocalRuntimeDocument, processID: Int32) -> Bool {
  guard let digest = document.deploymentSHA256 else { return false }
  let receipt = RuntimeDeploymentReceipt(processID: processID, contractSHA256: digest)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.sortedKeys]
  guard let data = try? encoder.encode(receipt) else { return false }
  do {
    try AtomicFileWriter.write(data, to: runtimeStatusFileURL)
    return true
  } catch {
    return false
  }
}

func clearRuntimeReceipt() {
  try? FileManager.default.removeItem(at: runtimeStatusFileURL)
}

func spawnSslocal(_ document: SslocalRuntimeDocument) -> Process? {
  guard FileManager.default.isExecutableFile(atPath: sslocalURL.path) else { return nil }
  let child = Process()
  child.executableURL = sslocalURL
  child.arguments = ["-c", contractURL.path]
  var childEnvironment = environment
  // 上游默认日志级别会把服务器地址写进普通日志（D5）：常规模式压到 warn，
  // 用户明确打开 verbose 后才放宽到 debug。显式外部 RUST_LOG 仍可用于诊断。
  if childEnvironment["RUST_LOG"] == nil {
    childEnvironment["RUST_LOG"] = document.pac.verbose ? "debug" : "warn"
  }
  child.environment = childEnvironment
  do {
    try child.run()
  } catch {
    return nil
  }
  RuntimeLog.emit(.sslocalSpawned(pid: child.processIdentifier))
  return child
}

// MARK: - 日志收敛

func redirectStandardStreams(to logURL: URL) {
  let fileManager = FileManager.default
  let directory = logURL.deletingLastPathComponent()
  try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
  try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
  if fileManager.fileExists(atPath: logURL.path) {
    let attributes = try? fileManager.attributesOfItem(atPath: logURL.path)
    if let size = attributes?[.size] as? UInt64, size > 1_048_576 {
      // 启动时超限即截断；滚动与诊断导出由 #33 完善。
      try? fileManager.removeItem(at: logURL)
    }
  }
  if !fileManager.fileExists(atPath: logURL.path) {
    fileManager.createFile(
      atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
  }
  try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: logURL.path)
  freopen(logURL.path, "a", stdout)
  freopen(logURL.path, "a", stderr)
}
