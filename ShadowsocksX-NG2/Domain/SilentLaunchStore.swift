import Foundation

/// 静默启动偏好持久化（ADR 0017）：落盘 `~/Library/Application Support/
/// ShadowsocksX-NG2/silent-launch.json`。GUI 呈现层独占的偏好文件，与
/// settings.json 有意分离——代理控制器按内存快照整写 settings.json，任何
/// 旁路字段都会被下一次整写覆盖。文件缺失、损坏或版本未知一律按安全侧
/// 默认「不静默」（启动照常呈现主窗口）。
struct SilentLaunchStore {
  enum PersistenceError: Error, Equatable {
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

  /// 默认位置：`~/Library/Application Support/ShadowsocksX-NG2/silent-launch.json`。
  static func defaultFileURL() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    return support.appendingPathComponent("ShadowsocksX-NG2/silent-launch.json")
  }

  init(fileURL: URL = SilentLaunchStore.defaultFileURL()) {
    self.fileURL = fileURL
  }

  /// 缺失/损坏/版本未知 → `false`（安全侧：不静默）。
  func loadSilentLaunchEnabled() -> Bool {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return false }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      return false
    }
    let payload = try? JSONDecoder().decode(SilentLaunchPayload.self, from: data)
    guard let payload, payload.version == Self.currentVersion else { return false }
    return payload.silentLaunchEnabled
  }

  /// 整体重写并原子替换；失败时保留原文件。
  func save(silentLaunchEnabled: Bool) throws {
    let data: Data
    do {
      data = try Self.jsonEncoder.encode(
        SilentLaunchPayload(version: Self.currentVersion, silentLaunchEnabled: silentLaunchEnabled))
    } catch {
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }
    do {
      try AtomicFileWriter.write(data, to: fileURL)
    } catch {
      throw PersistenceError.ioFailure(detail: String(describing: error))
    }
  }
}

/// 落盘文档形态：版本号 + 偏好布尔。
private struct SilentLaunchPayload: Codable {
  var version: Int
  var silentLaunchEnabled: Bool
}
