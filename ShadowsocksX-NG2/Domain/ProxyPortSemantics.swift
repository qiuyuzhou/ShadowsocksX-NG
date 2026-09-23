/// 本地代理端点的端口语义（spec #21 D8，issue #30）：端口是显式用户配置，
/// 出厂默认与 Legacy 隔离（SOCKS5 11086 / HTTP 11087 / PAC 11089）；系统任何路径
/// 都不静默改端口——建议端口只产出候选，必须经用户确认保存后才生效；激活
/// 是否成功以 runtime 实际绑定为准（健康门禁），本层的占用校验只是设置编辑
/// 期尽力而为的即时提示。

/// 三个本地代理端点；显示名与 D8 及诊断报告的措辞一致。
enum ProxyEndpointKind: Equatable, Sendable, CaseIterable {
  case socks
  case http
  case pac

  var displayName: String {
    switch self {
    case .socks: "SOCKS5"
    case .http: "HTTP"
    case .pac: "PAC"
    }
  }
}

/// 端口配置校验错误：点名端点与端口（D8 错误信息要求）。
enum PortSettingError: Error, Equatable, Sendable {
  case portOutOfRange(endpoint: ProxyEndpointKind, port: Int)
  /// 两个端点的配置端口相同；`endpoint` 在枚举序（socks → http → pac）中在前。
  case duplicatePort(endpoint: ProxyEndpointKind, otherEndpoint: ProxyEndpointKind, port: Int)
}

/// 建议空闲端口算法（D8）：32768–65535 高位段升序扫描，跳过排除集合与不
/// 空闲端口。空闲判定由调用方注入，保证主缝可测。
enum PortSuggestion {
  static let range = 32768...65535

  static func firstFree(excluding excludedPorts: Set<Int>, isFree: (Int) -> Bool) -> Int? {
    for candidate in range where !excludedPorts.contains(candidate) {
      if isFree(candidate) { return candidate }
    }
    return nil
  }
}

extension SslocalListenSettings {
  /// 三个端点的配置端口（与 HTTP 是否启用无关：配置值一律互异，避免日后
  /// 重新启用 HTTP 时才暴露冲突）。
  func configuredPort(for endpoint: ProxyEndpointKind) -> Int {
    switch endpoint {
    case .socks: socksPort
    case .http: httpPort
    case .pac: pacPort
    }
  }

  /// 端口配置校验：范围 1–65535、三端点配置值两两互异。错误按固定次序
  /// （socks/http/pac 范围检查，再 socks-http、socks-pac、http-pac 冲突）。
  func portValidationErrors() -> [PortSettingError] {
    var errors: [PortSettingError] = []
    for endpoint in ProxyEndpointKind.allCases {
      let port = configuredPort(for: endpoint)
      if !(1...65535).contains(port) {
        errors.append(.portOutOfRange(endpoint: endpoint, port: port))
      }
    }
    for pair in Self.endpointPairs {
      let first = configuredPort(for: pair.0)
      if first == configuredPort(for: pair.1) {
        errors.append(.duplicatePort(endpoint: pair.0, otherEndpoint: pair.1, port: first))
      }
    }
    return errors
  }

  /// 为 `endpoint` 建议一个空闲端口：高位段升序首个空闲且不等于另两个端点
  /// 配置值的候选；整段无可用返回 nil。只产出候选，绝不替用户改配置。
  func suggestedPort(for endpoint: ProxyEndpointKind, isFree: (Int) -> Bool) -> Int? {
    let others = Set(ProxyEndpointKind.allCases.filter { $0 != endpoint }.map(configuredPort))
    return PortSuggestion.firstFree(excluding: others, isFree: isFree)
  }

  private static let endpointPairs: [(ProxyEndpointKind, ProxyEndpointKind)] = [
    (.socks, .http), (.socks, .pac), (.http, .pac),
  ]
}

/// PAC 端口变更的结构化判定（D8）：已分享出去的 PAC URL 内嵌端口，换端口即
/// 失效，保存前必须提示。具体句子属于 App presentation edge。
enum PortChangeNotice {
  static func pacPortChanged(
    from previous: SslocalListenSettings, to next: SslocalListenSettings
  ) -> Bool {
    previous.pacPort != next.pacPort
  }
}
