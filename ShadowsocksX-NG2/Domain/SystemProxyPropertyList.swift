import Foundation

/// Pure projection of one SystemConfiguration Proxies dictionary. Keeping the
/// key mapping here makes the mutually exclusive enablement rules testable
/// without opening a real SCPreferences session. PAC projection is gone
/// (issue #67)；SOCKS 与 HTTP/HTTPS 同时指向本地入站（ADR 0012）。
enum SystemProxyPropertyList {
  static let httpEnabled = "HTTPEnable"
  static let httpsEnabled = "HTTPSEnable"
  static let socksEnabled = "SOCKSEnable"
  static let httpPort = "HTTPPort"
  static let httpProxy = "HTTPProxy"
  static let httpsPort = "HTTPSPort"
  static let httpsProxy = "HTTPSProxy"
  static let socksPort = "SOCKSPort"
  static let socksProxy = "SOCKSProxy"
  static let pacEnabled = "ProxyAutoConfigEnable"
  static let pacURL = "ProxyAutoConfigURLString"
  static let pacJavaScript = "ProxyAutoConfigJavaScript"
  static let autoDiscoveryEnabled = "ProxyAutoDiscoveryEnable"
  static let exceptionsList = "ExceptionsList"

  static func applying(
    _ configuration: SystemProxyConfiguration, to original: [String: Any]
  ) -> [String: Any] {
    var dictionary = original
    dictionary[socksEnabled] = 0
    dictionary[httpEnabled] = 0
    dictionary[httpsEnabled] = 0
    // 仍然清掉 PAC/自动发现，确保与本地入站目标互斥（D8）。
    dictionary[pacEnabled] = 0
    dictionary[autoDiscoveryEnabled] = 0
    dictionary.removeValue(forKey: pacJavaScript)
    dictionary.removeValue(forKey: pacURL)

    dictionary[socksEnabled] = 1
    dictionary[socksProxy] = configuration.socks.host
    dictionary[socksPort] = configuration.socks.port
    dictionary[httpEnabled] = 1
    dictionary[httpProxy] = configuration.http.host
    dictionary[httpPort] = configuration.http.port
    // HTTPS 系统代理 = HTTP 入站承接的 CONNECT 代理，端点与 HTTP 相同。
    dictionary[httpsEnabled] = 1
    dictionary[httpsProxy] = configuration.http.host
    dictionary[httpsPort] = configuration.http.port

    if let exceptions = configuration.exceptions {
      dictionary[exceptionsList] = exceptions
    }
    return dictionary
  }
}
