import Foundation

protocol PluginMappingStoring {
  func load() throws -> [String: String]
  func save(_ mappings: [String: String]) throws
}

enum PluginMappingError: Error, Equatable {
  case unreadable
  case unsupportedVersion
  case invalidName
  case invalidPath
  case unavailableFile
  case nameExists
  case nameMissing
}

struct PluginMappingFileStore: PluginMappingStoring {
  var fileURL = RuntimePaths.runtimeDirectory().appendingPathComponent("plugins.json")

  private struct Record: Codable {
    let version: Int
    let mappings: [String: String]
  }

  func load() throws -> [String: String] {
    // A missing file is empty; an unreadable or malformed file must not erase overrides.
    let data: Data
    do {
      data = try Data(contentsOf: fileURL)
    } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
      return [:]
    } catch {
      throw PluginMappingError.unreadable
    }
    let record: Record
    do {
      record = try JSONDecoder().decode(Record.self, from: data)
    } catch {
      throw PluginMappingError.unreadable
    }
    guard record.version == 1 else { throw PluginMappingError.unsupportedVersion }
    for (name, path) in record.mappings {
      guard name == name.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty,
        !name.contains("\0"), path.hasPrefix("/"), !path.contains("\0")
      else { throw PluginMappingError.unreadable }
    }
    return record.mappings
  }

  func save(_ mappings: [String: String]) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    try AtomicFileWriter.write(
      try encoder.encode(Record(version: 1, mappings: mappings)), to: fileURL)
  }
}
