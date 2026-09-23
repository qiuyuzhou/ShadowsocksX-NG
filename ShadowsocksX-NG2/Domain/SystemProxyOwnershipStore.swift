import Foundation

/// The original and last-applied per-service proxy dictionaries. `nil` means
/// that the service had no Proxies configuration before 2.0 took ownership.
struct SystemProxyOwnershipRecord: Codable, Equatable, Sendable {
  struct Entry: Codable, Equatable, Sendable {
    let serviceID: String
    let originalConfiguration: Data?
    let appliedConfiguration: Data
  }

  let entries: [Entry]
}

enum SystemProxyOwnershipStoreError: Error, Equatable, Sendable {
  case readFailed(String)
  case writeFailed(String)
  case invalidRecord
}

protocol SystemProxyOwnershipStoring {
  func load() throws -> SystemProxyOwnershipRecord?
  func save(_ record: SystemProxyOwnershipRecord) throws
  func clear() throws
}

/// Persists ownership separately from the user configuration tree so that a
/// GUI restart can restore only settings still owned by 2.0.
struct FileSystemSystemProxyOwnershipStore: SystemProxyOwnershipStoring {
  let fileURL: URL

  init(fileURL: URL = RuntimePaths.systemProxyOwnershipURL()) {
    self.fileURL = fileURL
  }

  func load() throws -> SystemProxyOwnershipRecord? {
    guard FileManager.default.fileExists(atPath: fileURL.path) else { return nil }
    do {
      let record = try JSONDecoder().decode(
        SystemProxyOwnershipRecord.self, from: Data(contentsOf: fileURL))
      let serviceIDs = record.entries.map(\.serviceID)
      guard
        record.entries.allSatisfy({ !$0.serviceID.isEmpty }),
        Set(serviceIDs).count == serviceIDs.count
      else {
        throw SystemProxyOwnershipStoreError.invalidRecord
      }
      return record
    } catch let error as SystemProxyOwnershipStoreError {
      throw error
    } catch {
      throw SystemProxyOwnershipStoreError.readFailed(String(describing: error))
    }
  }

  func save(_ record: SystemProxyOwnershipRecord) throws {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try AtomicFileWriter.write(try encoder.encode(record), to: fileURL)
    } catch {
      throw SystemProxyOwnershipStoreError.writeFailed(String(describing: error))
    }
  }

  func clear() throws {
    do {
      try FileManager.default.removeItem(at: fileURL)
    } catch CocoaError.fileNoSuchFile {
      return
    } catch {
      throw SystemProxyOwnershipStoreError.writeFailed(String(describing: error))
    }
  }
}
