import Foundation

enum SystemProxyEndpointSignatureStoreError: Error, Equatable, Sendable {
  case readFailed(String)
  case writeFailed(String)
}

protocol SystemProxyEndpointSignatureStoring {
  func load() throws -> SystemProxyEndpointSignature?
  func save(_ signature: SystemProxyEndpointSignature) throws
}

/// Persists only the endpoint signature needed to recognize settings during cleanup.
/// On upgrade, the legacy ownership file is inspected only for its last-applied
/// endpoint values; its original per-service configurations are never decoded or kept.
struct FileSystemProxyEndpointSignatureStore: SystemProxyEndpointSignatureStoring {
  let fileURL: URL
  let legacyOwnershipFileURL: URL

  init(
    fileURL: URL = RuntimePaths.systemProxyEndpointSignatureURL(),
    legacyOwnershipFileURL: URL = RuntimePaths.legacySystemProxyOwnershipURL()
  ) {
    self.fileURL = fileURL
    self.legacyOwnershipFileURL = legacyOwnershipFileURL
  }

  func load() throws -> SystemProxyEndpointSignature? {
    if FileManager.default.fileExists(atPath: fileURL.path) {
      let signature: SystemProxyEndpointSignature
      do {
        signature = try JSONDecoder().decode(
          SystemProxyEndpointSignature.self, from: Data(contentsOf: fileURL))
      } catch {
        throw SystemProxyEndpointSignatureStoreError.readFailed(String(describing: error))
      }
      guard signature.isValid else {
        throw SystemProxyEndpointSignatureStoreError.readFailed("invalid endpoint signature")
      }
      try removeLegacyOwnershipFile()
      return signature
    }

    guard FileManager.default.fileExists(atPath: legacyOwnershipFileURL.path) else { return nil }
    let migrated = try legacyEndpointSignature()
    // Remove the old dictionaries before writing the compact replacement. If the
    // process stops between these operations, cleanup may need manual attention, but
    // the application never keeps or restores the legacy snapshots.
    try removeLegacyOwnershipFile()
    if let migrated { try save(migrated) }
    return migrated
  }

  func save(_ signature: SystemProxyEndpointSignature) throws {
    do {
      let encoder = JSONEncoder()
      encoder.outputFormatting = [.sortedKeys]
      try AtomicFileWriter.write(try encoder.encode(signature), to: fileURL)
    } catch {
      throw SystemProxyEndpointSignatureStoreError.writeFailed(String(describing: error))
    }
  }

  private func legacyEndpointSignature() throws -> SystemProxyEndpointSignature? {
    let data: Data
    do {
      data = try Data(contentsOf: legacyOwnershipFileURL)
    } catch {
      throw SystemProxyEndpointSignatureStoreError.readFailed(String(describing: error))
    }
    // The decoding model intentionally has no `originalConfiguration` property.
    // JSONDecoder ignores that key, so the prior configuration cannot enter memory.
    guard let record = try? JSONDecoder().decode(LegacyOwnershipRecord.self, from: data),
      !record.entries.isEmpty
    else { return nil }

    let signatures = record.entries.compactMap { entry -> SystemProxyEndpointSignature? in
      guard
        let dictionary = try? PropertyListSerialization.propertyList(
          from: entry.appliedConfiguration, options: [], format: nil) as? [String: Any],
        let signature = Self.signature(from: dictionary)
      else { return nil }
      return signature
    }
    guard signatures.count == record.entries.count,
      let onlySignature = signatures.first,
      signatures.allSatisfy({ $0 == onlySignature })
    else { return nil }
    return onlySignature
  }

  private static func signature(from dictionary: [String: Any]) -> SystemProxyEndpointSignature? {
    guard
      let socksHost = dictionary[SystemProxyPropertyList.socksProxy] as? String,
      let socksPort = dictionary[SystemProxyPropertyList.socksPort] as? Int,
      let httpHost = dictionary[SystemProxyPropertyList.httpProxy] as? String,
      let httpPort = dictionary[SystemProxyPropertyList.httpPort] as? Int,
      let httpsHost = dictionary[SystemProxyPropertyList.httpsProxy] as? String,
      let httpsPort = dictionary[SystemProxyPropertyList.httpsPort] as? Int,
      (dictionary[SystemProxyPropertyList.socksEnabled] as? Int) == 1,
      (dictionary[SystemProxyPropertyList.httpEnabled] as? Int) == 1,
      (dictionary[SystemProxyPropertyList.httpsEnabled] as? Int) == 1,
      socksPort > 0, socksPort <= 65_535, httpPort > 0, httpPort <= 65_535,
      socksHost.isEmpty == false, httpHost == httpsHost, httpPort == httpsPort
    else { return nil }
    return SystemProxyEndpointSignature(
      socks: .init(host: socksHost, port: socksPort),
      http: .init(host: httpHost, port: httpPort))
  }

  private func removeLegacyOwnershipFile() throws {
    do {
      try FileManager.default.removeItem(at: legacyOwnershipFileURL)
    } catch CocoaError.fileNoSuchFile {
      return
    } catch {
      throw SystemProxyEndpointSignatureStoreError.writeFailed(String(describing: error))
    }
  }
}

private struct LegacyOwnershipRecord: Decodable {
  struct Entry: Decodable {
    let appliedConfiguration: Data
  }

  let entries: [Entry]
}
