import CryptoKit
import Foundation

/// Fixed local targets bypass the system proxy. Their IP ranges are also
/// included in the direct-mode sslocal ACL for requests reaching either inbound.
enum FixedLocalProxyRanges {
  static let ipRanges = [
    "127.0.0.0/8",
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "169.254.0.0/16",
    "::1/128",
    "fe80::/10",
    "fc00::/7",
  ]

  static let systemProxyHostExceptions = ["localhost", "*.local", "<local>"]

  static var systemProxyExceptions: [String] {
    ipRanges + systemProxyHostExceptions
  }

  static func systemProxyExceptions(including values: [String]?) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for value in systemProxyExceptions + (values ?? []) {
      let identity = value.lowercased()
      guard seen.insert(identity).inserted else { continue }
      result.append(value)
    }
    return result
  }

  static let aclHostRules = ["||localhost", "||local", "^[^.]+$"]

  static var aclBypassRules: [String] {
    ipRanges + aclHostRules
  }
}

/// A generated sslocal ACL and its safe runtime identity. The wrapper extension
/// carries the content so it can validate the sidecar before starting sslocal.
struct ProxyACLDocument: Codable, Equatable, Sendable {
  let path: String
  let summary: String
  let content: String
  let sha256: String

  init(path: String, summary: String, content: String) {
    self.init(path: path, summary: summary, content: content, sha256: Self.digest(content))
  }

  init(path: String, summary: String, content: String, sha256: String) {
    self.path = path
    self.summary = summary
    self.content = content
    self.sha256 = sha256
  }

  /// Direct mode deliberately has no `proxy_list`: `bypass_all` supplies the
  /// default, while the explicit fixed-local entries remain a safety policy
  /// shared by SOCKS and HTTP and reusable by later routing modes.
  static func direct(at fileURL: URL) -> ProxyACLDocument {
    let lines = ["[bypass_all]", "[bypass_list]"] + FixedLocalProxyRanges.aclBypassRules
    return ProxyACLDocument(
      path: fileURL.standardizedFileURL.path,
      summary: "direct",
      content: lines.joined(separator: "\n") + "\n")
  }

  var isWellFormed: Bool {
    path.hasPrefix("/")
      && !summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      && !content.isEmpty
      && content.utf8.allSatisfy { $0 < 128 }
      && sha256 == Self.digest(content)
  }

  static func digest(_ content: String) -> String {
    digest(Data(content.utf8))
  }

  static func digest(_ data: Data) -> String {
    SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
  }
}

/// Identifies the deployed sslocal child. The wrapper publishes ACL-backed
/// receipts only after that child owns every configured TCP listener.
struct RuntimeDeploymentReceipt: Codable, Equatable, Sendable {
  let processID: Int32
  let contractSHA256: String
}
