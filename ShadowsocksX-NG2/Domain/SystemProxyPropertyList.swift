import Foundation

/// Pure projection of one SystemConfiguration Proxies dictionary. Keeping the
/// key mapping here makes the mutually exclusive enablement rules testable
/// without opening a real SCPreferences session.
enum SystemProxyPropertyList {
  static let httpEnabled = "HTTPEnable"
  static let httpsEnabled = "HTTPSEnable"
  static let socksEnabled = "SOCKSEnable"
  static let socksPort = "SOCKSPort"
  static let socksProxy = "SOCKSProxy"
  static let pacEnabled = "ProxyAutoConfigEnable"
  static let pacURL = "ProxyAutoConfigURLString"
  static let pacJavaScript = "ProxyAutoConfigJavaScript"
  static let autoDiscoveryEnabled = "ProxyAutoDiscoveryEnable"

  static func applying(
    _ target: SystemProxyConfiguration.Target, to original: [String: Any]
  ) -> [String: Any] {
    var dictionary = original
    dictionary[httpEnabled] = 0
    dictionary[httpsEnabled] = 0
    dictionary[socksEnabled] = 0
    dictionary[pacEnabled] = 0
    dictionary[autoDiscoveryEnabled] = 0
    dictionary.removeValue(forKey: pacJavaScript)

    switch target {
    case .pac(let url):
      dictionary[pacEnabled] = 1
      dictionary[pacURL] = url.absoluteString
    case .socks(let host, let port):
      dictionary[socksEnabled] = 1
      dictionary[socksProxy] = host
      dictionary[socksPort] = port
    }
    return dictionary
  }
}
