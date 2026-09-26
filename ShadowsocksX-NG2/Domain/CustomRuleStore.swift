import Foundation

/// 自定义规则持久化（issue #66）：独立 JSON 文档，原子写盘。
/// 规则内容变化后由调用方重编译 ACL 并走完整重启及回滚路径生效。
struct CustomRuleStore {
  let fileURL: URL

  init(fileURL: URL = CustomRuleStore.defaultFileURL()) {
    self.fileURL = fileURL
  }

  static func defaultFileURL() -> URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    return support.appendingPathComponent("ShadowsocksX-NG2/custom-rules.json")
  }

  /// 读取规则集合；文件不存在视为无自定义规则。
  func load() throws -> [CustomRule] {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch {
      throw CustomRuleStoreError.ioFailure(detail: String(describing: error))
    }
    let document: CustomRuleDocument
    do {
      document = try Self.decode(data)
    } catch {
      throw CustomRuleStoreError.corrupt(detail: String(describing: error))
    }
    guard document.schemaVersion == CustomRuleDocument.currentSchemaVersion else {
      throw CustomRuleStoreError.schemaVersionMismatch(
        found: document.schemaVersion, expected: CustomRuleDocument.currentSchemaVersion)
    }
    return document.rules
  }

  /// 原子写入完整规则集合。
  func save(_ rules: [CustomRule]) throws {
    let data = try Self.encode(CustomRuleDocument(rules: rules))
    do {
      try AtomicFileWriter.write(data, to: fileURL)
    } catch {
      throw CustomRuleStoreError.ioFailure(detail: String(describing: error))
    }
  }

  /// 安全摘要：数量 + 内容版本（issue #66 AC5）。
  func summary() throws -> CustomRuleSummary {
    CustomRuleSummary.summarizing(try load())
  }

  static func decode(_ data: Data) throws -> CustomRuleDocument {
    try JSONDecoder().decode(CustomRuleDocument.self, from: data)
  }

  static func encode(_ document: CustomRuleDocument) throws -> Data {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return try encoder.encode(document)
  }
}
