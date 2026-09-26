import Foundation

/// 运行时文件存取（spec #21 D5，issue #27；ACL 布局见 ADR-0011）：
/// `sslocal-active.json` 是 GUI 写、wrapper 读的跨进程交接契约。ACL 侧为
/// 每个变体一个 `acl-<summary>.ini` 实文件，外加稳定的 `acl-active.ini` 链接；
/// 契约只携带链接路径与身份摘要。写入复用 `AtomicFileWriter` 的物理安全基线
/// （目录 0700 含自愈、临时文件创建即 0600、写全校验后原子替换）；显式停止
/// 后的清理只做普通 unlink，不承诺安全擦除（D5）。
struct RuntimeFileStore {
  enum PersistenceError: Error, Equatable {
    /// 写入时的文件系统错误。
    case ioFailure(detail: String)
    /// Runtime JSON 写失败后无法恢复此前的 ACL 变体或链接。
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

  private var directoryURL: URL { fileURL.deletingLastPathComponent() }

  /// wrapper pid 文件与契约同目录：GUI 判活与 SIGUSR1 投递依据
  /// （SMAppService 不暴露运行中 agent 的 pid）。
  var pidFileURL: URL {
    directoryURL.appendingPathComponent("agent.pid")
  }

  /// 稳定 ACL 链接（ADR-0011）：契约 `acl` 字段恒指向它，换模式只改链接。
  var aclFileURL: URL {
    directoryURL.appendingPathComponent("acl-active.ini")
  }

  /// 某个 ACL 变体的实文件。
  func aclVariantFileURL(summary: String) -> URL {
    directoryURL.appendingPathComponent("acl-\(summary).ini")
  }

  /// GUI 私有 digest 清单：未变内容免读免写。
  var aclDigestManifestURL: URL {
    directoryURL.appendingPathComponent("acl-digests.json")
  }

  var runtimeStatusFileURL: URL {
    directoryURL.appendingPathComponent("agent-runtime-status.json")
  }

  /// 原子写盘；任一步失败保留原文件。
  func write(_ document: SslocalRuntimeDocument) throws {
    let data: Data
    do {
      data = try document.jsonData()
    } catch {
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }

    var previousVariantData: Data?
    var previousLinkTarget: String?
    var wroteVariant = false
    if let acl = document.aclRuntime {
      guard
        acl.path == aclFileURL.standardizedFileURL.path,
        acl.isWellFormed
      else {
        throw PersistenceError.ioFailure(detail: "ACL sidecar path or digest is invalid")
      }
      let variantURL = aclVariantFileURL(summary: acl.summary)
      previousLinkTarget = try? FileManager.default.destinationOfSymbolicLink(
        atPath: aclFileURL.path)
      do {
        if !acl.content.isEmpty {
          previousVariantData = try? Data(contentsOf: variantURL)
          if try shouldWriteVariant(summary: acl.summary, sha256: acl.sha256, at: variantURL) {
            try fileWriter(Data(acl.content.utf8), variantURL)
            wroteVariant = true
          }
        }
        try repointActiveLink(to: variantURL)
      } catch {
        try? restoreVariant(previousVariantData, at: variantURL)
        try? restoreLink(previousLinkTarget)
        throw PersistenceError.ioFailure(detail: String(describing: error))
      }
    }

    do {
      try fileWriter(data, fileURL)
    } catch {
      if let acl = document.aclRuntime {
        do {
          try restoreVariant(previousVariantData, at: aclVariantFileURL(summary: acl.summary))
          try restoreLink(previousLinkTarget)
        } catch {
          throw PersistenceError.rollbackFailed(detail: String(describing: error))
        }
      }
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }
    // digest 清单只是跳写缓存：契约写成功后才登记，失败回滚不会留下
    // 「清单说新内容、盘上是旧内容」的脱节（下轮退化为全量哈希仍正确）。
    if wroteVariant, let acl = document.aclRuntime {
      recordDigest(summary: acl.summary, sha256: acl.sha256, size: acl.content.utf8.count)
    }
  }

  /// 读取侧判定：结构有效 + 链接解析后仍在运行目录内。不读 ACL 内容、
  /// 不核摘要（ADR-0011 / Q12）。
  func loadDocument() -> SslocalRuntimeDocument? {
    guard let data = try? Data(contentsOf: fileURL) else { return nil }
    guard let document = SslocalRuntimeDocument.decodeValidated(data) else { return nil }
    guard let acl = document.aclRuntime else { return document }
    guard
      acl.path == aclFileURL.standardizedFileURL.path,
      activeLinkResolvesInsideDirectory()
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

  /// 显式停止清理（D2 停止协议末端）：运行时契约、wrapper pid、ACL 链接与
  /// 变体、digest 清单及原子写残留。异常崩溃路径不调用本方法（文件保留供
  /// KeepAlive 重放，D5）。文件缺失时调用无害。
  func deleteRuntimeFiles() {
    let fileManager = FileManager.default
    try? fileManager.removeItem(at: fileURL)
    try? fileManager.removeItem(at: pidFileURL)
    try? fileManager.removeItem(at: aclFileURL)
    try? fileManager.removeItem(at: aclDigestManifestURL)
    try? fileManager.removeItem(at: runtimeStatusFileURL)
    try? fileManager.removeItem(at: directoryURL.appendingPathComponent("sslocal-active.acl"))
    if let names = try? fileManager.contentsOfDirectory(atPath: directoryURL.path) {
      for name in names {
        // 变体实文件，或 AtomicFileWriter 的 `.<name>.tmp-<uuid>` 残留。
        if name.hasPrefix("acl-") && name.hasSuffix(".ini") {
          try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
        } else if name.hasPrefix(".") && name.contains(".tmp-") {
          try? fileManager.removeItem(at: directoryURL.appendingPathComponent(name))
        }
      }
    }
  }

  // MARK: - ACL 变体与链接

  /// digest 清单命中（摘要 + 字节数一致）且文件在盘则跳过写；清单失效时
  /// 退化为对文件做一次全量哈希确认（ADR-0011）。
  private func shouldWriteVariant(summary: String, sha256: String, at variantURL: URL) throws
    -> Bool
  {
    let fileManager = FileManager.default
    if let recorded = loadDigestManifest()[summary], recorded.sha256 == sha256 {
      let attributes = try? fileManager.attributesOfItem(atPath: variantURL.path)
      let size = (attributes?[.size] as? NSNumber)?.intValue
      if size == recorded.size { return false }
    }
    if let existing = try? Data(contentsOf: variantURL), ProxyACLDocument.digest(existing) == sha256
    {
      recordDigest(summary: summary, sha256: sha256, size: existing.count)
      return false
    }
    return true
  }

  private struct DigestEntry: Codable, Equatable {
    let sha256: String
    let size: Int
  }

  private func loadDigestManifest() -> [String: DigestEntry] {
    guard let data = try? Data(contentsOf: aclDigestManifestURL) else { return [:] }
    return (try? JSONDecoder().decode([String: DigestEntry].self, from: data)) ?? [:]
  }

  private func recordDigest(summary: String, sha256: String, size: Int) {
    var manifest = loadDigestManifest()
    manifest[summary] = DigestEntry(sha256: sha256, size: size)
    guard let data = try? JSONEncoder().encode(manifest) else { return }
    try? fileWriter(data, aclDigestManifestURL)
  }

  private func repointActiveLink(to variantURL: URL) throws {
    let fileManager = FileManager.default
    let temporaryLink = directoryURL.appendingPathComponent(
      ".\(aclFileURL.lastPathComponent).tmp-\(UUID().uuidString)")
    try? fileManager.removeItem(at: temporaryLink)
    try fileManager.createSymbolicLink(
      atPath: temporaryLink.path, withDestinationPath: variantURL.lastPathComponent)
    if fileManager.fileExists(atPath: aclFileURL.path)
      || (try? fileManager
        .destinationOfSymbolicLink(atPath: aclFileURL.path)) != nil
    {
      // rename 原子替换既有链接/文件。
      guard rename(temporaryLink.path, aclFileURL.path) == 0 else {
        try? fileManager.removeItem(at: temporaryLink)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } else {
      try fileManager.moveItem(at: temporaryLink, to: aclFileURL)
    }
  }

  private func restoreVariant(_ previousData: Data?, at variantURL: URL) throws {
    if let previousData {
      try fileWriter(previousData, variantURL)
    } else {
      try? FileManager.default.removeItem(at: variantURL)
    }
  }

  private func restoreLink(_ previousTarget: String?) throws {
    let fileManager = FileManager.default
    if let previousTarget {
      let temporaryLink = directoryURL.appendingPathComponent(
        ".\(aclFileURL.lastPathComponent).tmp-\(UUID().uuidString)")
      try? fileManager.removeItem(at: temporaryLink)
      try fileManager.createSymbolicLink(
        atPath: temporaryLink.path, withDestinationPath: previousTarget)
      guard rename(temporaryLink.path, aclFileURL.path) == 0 else {
        try? fileManager.removeItem(at: temporaryLink)
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
      }
    } else {
      try? fileManager.removeItem(at: aclFileURL)
    }
  }

  /// 链接（或实文件）解析后必须仍在运行目录内——防链接逃逸（ADR-0011）。
  private func activeLinkResolvesInsideDirectory() -> Bool {
    ACLActiveLinkPolicy.resolvesToRegularFile(inside: directoryURL, linkURL: aclFileURL)
  }
}
