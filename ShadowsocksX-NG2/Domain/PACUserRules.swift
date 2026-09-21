import Foundation

/// PAC 用户规则的最小、可审计子集：只有明确的 `@@` 例外规则会把请求
/// 改为 DIRECT；其余规则不改变当前默认的 SOCKS 优先策略。
enum PACRuleSet {
  static func directHostSuffixes(from rules: String) -> [String] {
    var result: [String] = []
    var seen = Set<String>()
    for rawLine in rules.split(whereSeparator: \.isNewline) {
      let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
      guard line.hasPrefix("@@") else { continue }
      guard let host = host(from: String(line.dropFirst(2))) else { continue }
      guard seen.insert(host).inserted else { continue }
      result.append(host)
    }
    return result
  }

  private static func host(from rule: String) -> String? {
    var value = rule
    while value.hasPrefix("|") { value.removeFirst() }
    if value.hasPrefix("http://") || value.hasPrefix("https://"),
      let url = URL(string: value), let host = url.host
    {
      return normalized(host)
    }
    if value.hasPrefix("||") { value.removeFirst(2) }
    let delimiters = CharacterSet(charactersIn: "^|/")
    let host = value.components(separatedBy: delimiters).first ?? value
    return normalized(host)
  }

  private static func normalized(_ host: String) -> String? {
    let value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !value.isEmpty, value.contains(".") || value == "localhost" else { return nil }
    guard !value.contains("\\") && !value.contains("\"") else { return nil }
    return value.hasPrefix(".") ? String(value.dropFirst()) : value
  }
}
