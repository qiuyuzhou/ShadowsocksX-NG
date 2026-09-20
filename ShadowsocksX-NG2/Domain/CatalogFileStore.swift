import Foundation

/// 配置树磁盘持久化（spec #21 D5）：落盘 `~/Library/Application Support/
/// ShadowsocksX-NG/v2/catalog.json`，`v2/` 权限 0700、文件 0600；写临时文件
/// （创建即 0600）后原子替换。文件只含结构化目录与凭据引用，永不落秘密明文。
struct CatalogFileStore {
  enum PersistenceError: Error, Equatable {
    /// 文件存在但不是本模型可接受的目录文档：JSON 损坏、版本未知、结构不一致。
    case corrupt(detail: String)
    /// 读取或写入时的文件系统错误。
    case ioFailure(detail: String)
  }

  private static let currentVersion = 1
  private static let jsonEncoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
  }()

  let fileURL: URL

  /// 默认位置：`~/Library/Application Support/ShadowsocksX-NG/v2/catalog.json`。
  static func defaultFileURL() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    return support.appendingPathComponent("ShadowsocksX-NG/v2/catalog.json")
  }

  /// 文件缺失 → 全新空目录；存在但损坏/版本未知/结构不一致 → `.corrupt`。
  func load() throws -> ConfigurationCatalog {
    guard FileManager.default.fileExists(atPath: fileURL.path) else {
      return ConfigurationCatalog()
    }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }
    return try decode(data)
  }

  /// 整体重写并原子替换；失败时保留原文件。目录按 D5 基线强制 0700（含自愈）。
  func save(_ catalog: ConfigurationCatalog) throws {
    let payload = CatalogFilePayload(
      version: Self.currentVersion,
      rootChildren: catalog.rootChildren,
      entries: catalog.entries.values.sorted { $0.id.rawValue < $1.id.rawValue }
    )
    let data: Data
    do {
      data = try Self.jsonEncoder.encode(payload)
    } catch {
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }
    do {
      try AtomicFileWriter.write(data, to: fileURL)
    } catch {
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }
  }

  private func decode(_ data: Data) throws -> ConfigurationCatalog {
    let payload: CatalogFilePayload
    do {
      payload = try JSONDecoder().decode(CatalogFilePayload.self, from: data)
    } catch {
      throw PersistenceError.corrupt(detail: String(describing: error))
    }
    guard payload.version == Self.currentVersion else {
      throw PersistenceError.corrupt(detail: "unsupported version \(payload.version)")
    }
    var entries: [NodeID: CatalogEntry] = [:]
    for entry in payload.entries {
      guard entries[entry.id] == nil else {
        throw PersistenceError.corrupt(detail: "duplicate node id \(entry.id.rawValue)")
      }
      entries[entry.id] = entry
    }
    do {
      return try ConfigurationCatalog.validated(
        rootChildren: payload.rootChildren, entries: entries)
    } catch let error as CatalogError {
      throw PersistenceError.corrupt(detail: String(describing: error))
    }
  }
}

/// 落盘文档形态：版本号 + 根子序 + 全量节点表（顺序语义在根序与分组显子序中）。
private struct CatalogFilePayload: Codable {
  var version: Int
  var rootChildren: [NodeID]
  var entries: [CatalogEntry]
}
