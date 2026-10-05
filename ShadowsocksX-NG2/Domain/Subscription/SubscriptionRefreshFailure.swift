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

  /// 无 payload 的失败值 ↔ kind 对照表：编解码共用，保持与 Kind 枚举一一对应。
  private static let payloadlessKinds: [(kind: Kind, failure: SubscriptionRefreshFailure)] = [
    (.invalidURL, .invalidURL),
    (.unsupportedScheme, .unsupportedScheme),
    (.insecureRedirect, .insecureRedirect),
    (.decodingFailure, .decodingFailure),
    (.unsupportedSchemaVersion, .unsupportedSchemaVersion),
    (.missingServers, .missingServers),
    (.duplicateIdentity, .duplicateIdentity),
    (.legacy, .legacy),
    (.unknown, .unknown),
  ]

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let kind = try container.decode(Kind.self, forKey: .kind)
    if let payloadless = Self.payloadlessKinds.first(where: { $0.kind == kind })?.failure {
      self = payloadless
    } else {
      self = try Self.decodePayload(kind: kind, from: container)
    }
  }

  /// 带 payload 的 kind → 关联值解码；无 payload 的 kind 由对照表处理，
  /// 这里显式列出以保持对 Kind 枚举的穷举检查。
  private static func decodePayload(
    kind: Kind, from container: KeyedDecodingContainer<CodingKeys>
  ) throws -> SubscriptionRefreshFailure {
    switch kind {
    case .transport:
      return .transport(try container.decode(TransportCategory.self, forKey: .category))
    case .httpStatus:
      return .httpStatus(code: try container.decode(Int.self, forKey: .code))
    case .contentType:
      return .contentType(try container.decode(ContentTypeCategory.self, forKey: .category))
    case .recordValidation:
      return .recordValidation(
        index: try container.decode(Int.self, forKey: .index),
        field: try container.decode(RecordField.self, forKey: .field))
    case .credential:
      return .credential(category: try container.decode(CredentialCategory.self, forKey: .category))
    case .commit:
      return .commit(
        category: try container.decode(CommitCategory.self, forKey: .category),
        rollback: try container.decode(CredentialRollbackStatus.self, forKey: .rollback))
    case .invalidURL, .unsupportedScheme, .insecureRedirect, .decodingFailure,
      .unsupportedSchemaVersion, .missingServers, .duplicateIdentity, .legacy, .unknown:
      preconditionFailure("无 payload 的失败种类应由对照表处理")
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(kind, forKey: .kind)
    try encodePayload(to: &container)
  }

  private var kind: Kind {
    if let kind = Self.payloadlessKinds.first(where: { $0.failure == self })?.kind {
      return kind
    }
    switch self {
    case .transport:
      return .transport
    case .httpStatus:
      return .httpStatus
    case .contentType:
      return .contentType
    case .recordValidation:
      return .recordValidation
    case .credential:
      return .credential
    case .commit:
      return .commit
    case .invalidURL, .unsupportedScheme, .insecureRedirect, .decodingFailure,
      .unsupportedSchemaVersion, .missingServers, .duplicateIdentity, .legacy, .unknown:
      preconditionFailure("无 payload 的失败种类应由对照表处理")
    }
  }

  /// 仅 payload 字段；kind 已由 encode(to:) 写入。穷举保持编译期检查。
  private func encodePayload(to container: inout KeyedEncodingContainer<CodingKeys>) throws {
    switch self {
    case .transport(let category):
      try container.encode(category, forKey: .category)
    case .httpStatus(let code):
      try container.encode(code, forKey: .code)
    case .contentType(let category):
      try container.encode(category, forKey: .category)
    case .recordValidation(let index, let field):
      try container.encode(index, forKey: .index)
      try container.encode(field, forKey: .field)
    case .credential(let category):
      try container.encode(category, forKey: .category)
    case .commit(let category, let rollback):
      try container.encode(category, forKey: .category)
      try container.encode(rollback, forKey: .rollback)
    case .invalidURL, .unsupportedScheme, .insecureRedirect, .decodingFailure,
      .unsupportedSchemaVersion, .missingServers, .duplicateIdentity, .legacy, .unknown:
      break
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
