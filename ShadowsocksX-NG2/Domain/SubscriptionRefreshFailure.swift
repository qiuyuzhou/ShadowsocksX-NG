import Foundation

/// Safe, durable facts for the most recent subscription refresh failure.
///
/// This type is deliberately a closed whitelist. It carries enough information
/// for a presentation edge to explain the failure, but never stores a URL,
/// token, credential reference, arbitrary platform description, or raw parser
/// detail in the catalog.
enum SubscriptionRefreshFailure: Codable, Equatable, Sendable {
  enum TransportCategory: String, Codable, Equatable, Sendable {
    case timedOut
    case tls
    case connection
    case unknown
  }

  enum ContentTypeCategory: String, Codable, Equatable, Sendable {
    case missing
    case unsupported
  }

  enum RecordField: String, Codable, Equatable, Sendable {
    case address
    case port
    case method
    case password
    case identity
  }

  enum CredentialCategory: String, Codable, Equatable, Sendable {
    case missing
    case read
    case write
  }

  enum CommitCategory: String, Codable, Equatable, Sendable {
    case persistence
    case credentials
  }

  case invalidURL
  case unsupportedScheme
  case insecureRedirect
  case transport(TransportCategory)
  case httpStatus(code: Int)
  case contentType(ContentTypeCategory)
  case decodingFailure
  case unsupportedSchemaVersion
  case missingServers
  case recordValidation(index: Int, field: RecordField)
  case duplicateIdentity
  case credential(category: CredentialCategory)
  case commit(category: CommitCategory, rollback: CredentialRollbackStatus)
  /// Failure text loaded from a pre-v4 document. The old detail is intentionally
  /// discarded and cannot be written back.
  case legacy
  case unknown

  private enum CodingKeys: String, CodingKey {
    case kind
    case category
    case code
    case index
    case field
    case rollback
  }

  private enum Kind: String, Codable {
    case invalidURL
    case unsupportedScheme
    case insecureRedirect
    case transport
    case httpStatus
    case contentType
    case decodingFailure
    case unsupportedSchemaVersion
    case missingServers
    case recordValidation
    case duplicateIdentity
    case credential
    case commit
    case legacy
    case unknown
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    switch try container.decode(Kind.self, forKey: .kind) {
    case .invalidURL:
      self = .invalidURL
    case .unsupportedScheme:
      self = .unsupportedScheme
    case .insecureRedirect:
      self = .insecureRedirect
    case .transport:
      self = .transport(try container.decode(TransportCategory.self, forKey: .category))
    case .httpStatus:
      self = .httpStatus(code: try container.decode(Int.self, forKey: .code))
    case .contentType:
      self = .contentType(try container.decode(ContentTypeCategory.self, forKey: .category))
    case .decodingFailure:
      self = .decodingFailure
    case .unsupportedSchemaVersion:
      self = .unsupportedSchemaVersion
    case .missingServers:
      self = .missingServers
    case .recordValidation:
      self = .recordValidation(
        index: try container.decode(Int.self, forKey: .index),
        field: try container.decode(RecordField.self, forKey: .field))
    case .duplicateIdentity:
      self = .duplicateIdentity
    case .credential:
      self = .credential(category: try container.decode(CredentialCategory.self, forKey: .category))
    case .commit:
      self = .commit(
        category: try container.decode(CommitCategory.self, forKey: .category),
        rollback: try container.decode(CredentialRollbackStatus.self, forKey: .rollback))
    case .legacy:
      self = .legacy
    case .unknown:
      self = .unknown
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .invalidURL:
      try container.encode(Kind.invalidURL, forKey: .kind)
    case .unsupportedScheme:
      try container.encode(Kind.unsupportedScheme, forKey: .kind)
    case .insecureRedirect:
      try container.encode(Kind.insecureRedirect, forKey: .kind)
    case .transport(let category):
      try container.encode(Kind.transport, forKey: .kind)
      try container.encode(category, forKey: .category)
    case .httpStatus(let code):
      try container.encode(Kind.httpStatus, forKey: .kind)
      try container.encode(code, forKey: .code)
    case .contentType(let category):
      try container.encode(Kind.contentType, forKey: .kind)
      try container.encode(category, forKey: .category)
    case .decodingFailure:
      try container.encode(Kind.decodingFailure, forKey: .kind)
    case .unsupportedSchemaVersion:
      try container.encode(Kind.unsupportedSchemaVersion, forKey: .kind)
    case .missingServers:
      try container.encode(Kind.missingServers, forKey: .kind)
    case .recordValidation(let index, let field):
      try container.encode(Kind.recordValidation, forKey: .kind)
      try container.encode(index, forKey: .index)
      try container.encode(field, forKey: .field)
    case .duplicateIdentity:
      try container.encode(Kind.duplicateIdentity, forKey: .kind)
    case .credential(let category):
      try container.encode(Kind.credential, forKey: .kind)
      try container.encode(category, forKey: .category)
    case .commit(let category, let rollback):
      try container.encode(Kind.commit, forKey: .kind)
      try container.encode(category, forKey: .category)
      try container.encode(rollback, forKey: .rollback)
    case .legacy:
      try container.encode(Kind.legacy, forKey: .kind)
    case .unknown:
      try container.encode(Kind.unknown, forKey: .kind)
    }
  }
}

/// Coarse credential recovery status allowed in persisted subscription state.
/// The full `CredentialRollbackOutcome` remains transient and stays in memory.
enum CredentialRollbackStatus: String, Codable, Equatable, Sendable {
  case notNeeded
  case restored
  case incomplete
}

extension SubscriptionRefreshFailure {
  /// The only conversion point for transport failures entering durable state.
  static func from(fetchError: SubscriptionFetchError) -> Self {
    switch fetchError {
    case .invalidURL:
      .invalidURL
    case .unsupportedScheme:
      .unsupportedScheme
    case .insecureRedirect:
      .insecureRedirect
    case .transport(let detail):
      .transport(transportCategory(for: detail))
    case .httpStatus(let code):
      .httpStatus(code: code)
    case .contentType(let received):
      .contentType(received == nil ? .missing : .unsupported)
    }
  }

  /// The only conversion point for parser failures entering durable state.
  static func from(parseError: SubscriptionParseError) -> Self {
    switch parseError {
    case .decodingFailure:
      .decodingFailure
    case .unsupportedSchemaVersion:
      .unsupportedSchemaVersion
    case .missingServers:
      .missingServers
    case .recordValidation(let index, let reason):
      .recordValidation(index: index, field: recordField(for: reason))
    case .duplicateServerID:
      .duplicateIdentity
    }
  }

  static func from(credentialError: CredentialStoreError, category: CredentialCategory) -> Self {
    switch category {
    case .missing:
      .credential(category: .missing)
    case .read:
      .credential(category: .read)
    case .write:
      .credential(category: .write)
    }
  }

  static func rollbackStatus(for outcome: CredentialRollbackOutcome) -> CredentialRollbackStatus {
    switch outcome {
    case .nothingToRestore:
      .notNeeded
    case .restored:
      .restored
    case .partial:
      .incomplete
    }
  }

  private static func transportCategory(for detail: String) -> TransportCategory {
    let normalized = detail.lowercased()
    if normalized.contains("timedout") || normalized.contains("timeout") {
      return .timedOut
    }
    if normalized.contains("tls") || normalized.contains("secure") {
      return .tls
    }
    if normalized.contains("connection") || normalized.contains("network")
      || normalized.contains("cannotconnect")
    {
      return .connection
    }
    return .unknown
  }

  private static func recordField(for reason: String) -> RecordField {
    switch reason {
    case let value where value.contains("server_port"):
      .port
    case let value where value.contains("server"):
      .address
    case let value where value.contains("method"):
      .method
    case let value where value.contains("password"):
      .password
    case let value where value.contains("id"):
      .identity
    default:
      .identity
    }
  }
}
