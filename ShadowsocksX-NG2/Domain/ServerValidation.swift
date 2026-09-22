import Foundation

/// 加密方式能力目录（与当前随 app 打包的 sslocal 版本保持一致）。
/// 目录值是本地可验证的能力事实，不代表远端服务器一定可达。
enum EncryptionMethodCatalog {
  static let supported: Set<String> = [
    "aes-128-gcm",
    "aes-256-gcm",
    "chacha20-ietf-poly1305",
    "2022-blake3-aes-128-gcm",
    "2022-blake3-aes-256-gcm",
    "2022-blake3-chacha20-poly1305",
    "none",
  ]

  static func isSupported(_ method: String) -> Bool {
    supported.contains(method)
  }
}

/// 服务器配置的 app 可知校验结果。插件参数保持 opaque，不在此处判断其语法或
/// 远端握手；空 issues 只表示没有已知的本地激活阻塞原因。
struct ServerValidation: Equatable, Sendable {
  let issues: [LeafInvalidationReason]

  var isValid: Bool { issues.isEmpty }

  static func evaluate(
    _ fields: ServerFields,
    credentials: CredentialStoring,
    plugins: ManagedPluginProviding
  ) -> ServerValidation {
    var issues: [LeafInvalidationReason] = []
    appendAddressIssue(fields.address, to: &issues)
    appendPortIssue(fields.port, to: &issues)
    appendMethodIssue(fields.encryptionMethod, to: &issues)
    appendCredentialIssue(fields.passwordRef, credentials: credentials, to: &issues)
    appendPluginIssues(fields, credentials: credentials, plugins: plugins, to: &issues)
    return ServerValidation(issues: issues)
  }

  private static func appendAddressIssue(
    _ address: String, to issues: inout [LeafInvalidationReason]
  ) {
    if address.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      issues.append(.invalidAddress)
    }
  }

  private static func appendPortIssue(
    _ port: Int, to issues: inout [LeafInvalidationReason]
  ) {
    if !(1...65_535).contains(port) { issues.append(.invalidPort(port)) }
  }

  private static func appendMethodIssue(
    _ method: String, to issues: inout [LeafInvalidationReason]
  ) {
    let trimmed = method.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.isEmpty {
      issues.append(.missingEncryptionMethod)
    } else if !EncryptionMethodCatalog.isSupported(trimmed) {
      issues.append(.unsupportedEncryptionMethod(trimmed))
    }
  }

  private static func appendCredentialIssue(
    _ reference: CredentialReference,
    credentials: CredentialStoring,
    to issues: inout [LeafInvalidationReason]
  ) {
    if case .failure(let issue) = resolveCredential(reference, credentials: credentials) {
      issues.append(issue)
    }
  }

  private static func appendPluginIssues(
    _ fields: ServerFields,
    credentials: CredentialStoring,
    plugins: ManagedPluginProviding,
    to issues: inout [LeafInvalidationReason]
  ) {
    guard let program = fields.pluginProgram else { return }
    if plugins.executablePath(forProgram: program) == nil {
      issues.append(.pluginNotProvided(program: program))
    }
    if let optionsRef = fields.pluginOptionsRef {
      appendCredentialIssue(optionsRef, credentials: credentials, to: &issues)
    }
  }

  private static func resolveCredential(
    _ reference: CredentialReference,
    credentials: CredentialStoring
  ) -> Result<String, LeafInvalidationReason> {
    do {
      guard let secret = try credentials.secret(for: reference), !secret.isEmpty else {
        return .failure(.credentialUnresolved(reference))
      }
      return .success(secret)
    } catch {
      return .failure(.credentialReadFailed(reference))
    }
  }
}
