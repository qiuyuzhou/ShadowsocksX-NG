import Foundation

enum PACHealthOutcome: Equatable, Sendable {
  case reachable
  case failed(detail: String)
}

protocol PACHealthProbing: Sendable {
  func probe(url: URL, timeout: TimeInterval) async -> PACHealthOutcome
}

struct SystemPACHealthProbe: PACHealthProbing {
  func probe(url: URL, timeout: TimeInterval) async -> PACHealthOutcome {
    var request = URLRequest(
      url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
    request.httpMethod = "GET"
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
        return .failed(detail: "HTTP 状态异常")
      }
      guard http.mimeType == "application/x-ns-proxy-autoconfig" else {
        return .failed(detail: "PAC MIME 类型不正确")
      }
      guard String(data: data, encoding: .utf8)?.contains("FindProxyForURL") == true else {
        return .failed(detail: "PAC 内容无效")
      }
      return .reachable
    } catch {
      return .failed(detail: String(describing: error))
    }
  }
}
