import Darwin
import XCTest

@testable import ShadowsocksX_NG2

extension RealSslocalSmokeTests {
  /// 自定义规则真实 sslocal 路由（issue #66 AC4）：「未匹配时代理」下自定义
  /// 域名直连不触 SS 出口，未匹配目标走代理；SOCKS 与 HTTP 入站共用 ACL。
  func testCustomRulesRouteOnSOCKSAndHTTPInProxyDefaultMode() throws {
    let echoServer = try LoopbackEchoServer()
    let fakeSSServer = try ConnectionCountingServer()
    let selectedPorts = try grabThreeListenPorts(excluding: [echoServer.port, fakeSSServer.port])
    let listen = SslocalListenSettings(
      socksPort: selectedPorts[0], httpPort: selectedPorts[1], pacPort: selectedPorts[2])
    let customSource = RuleSourceIdentity(
      kind: .custom, upstreamVersion: "user", label: "自定义")
    let customRules = [
      ProxyRule(
        action: .direct, match: try RuleMatch(domainSuffix: "direct.example"),
        source: customSource),
      ProxyRule(
        action: .direct, match: try RuleMatch(domainExact: "exact.direct.example"),
        source: customSource),
      ProxyRule(
        action: .direct, match: try RuleMatch(ipv4CIDR: "203.0.113.0/24"),
        source: customSource),
    ]
    let document = SslocalRuntimeDocument(
      servers: [
        SslocalServerDocument(
          id: "custom-smoke-server",
          remarks: "custom-smoke",
          server: "127.0.0.1",
          serverPort: fakeSSServer.port,
          password: "smoke-password",
          method: "aes-256-gcm",
          plugin: nil,
          pluginOpts: nil)
      ],
      listen: listen,
      acl: .rule(
        at: workDir.appendingPathComponent("sslocal-active.acl"),
        defaultAction: .proxyWhenUnmatched,
        rules: customRules))
    XCTAssertTrue(document.isWellFormed)
    let wrapper = try launchWrapper(document)
    defer {
      if wrapper.isRunning { kill(wrapper.processIdentifier, SIGTERM) }
    }

    try awaitGlobalInboundsReady(listen: listen, document: document)
    try assertCustomDirectRulesBypass(listen: listen, fakeSS: fakeSSServer)
    try assertCustomUnmatchedProxies(listen: listen, fakeSS: fakeSSServer)

    stopWrapperAndAssertCleanExit(wrapper, description: "custom rule wrapper exits")
  }

  /// 自定义直连候选（域名后缀/完整域名/IPv4 CIDR）不得触达 SS 出口。
  private func assertCustomDirectRulesBypass(
    listen: SslocalListenSettings, fakeSS: ConnectionCountingServer
  ) throws {
    let beforeDirect = fakeSS.connectionCount
    performSocksConnectReply(
      socksPort: listen.socksPort, targetHost: "sub.direct.example", targetPort: 443)
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(
      fakeSS.connectionCount, beforeDirect,
      "自定义域名后缀直连规则不得触达 Shadowsocks 出口")

    performSocksConnectReply(
      socksPort: listen.socksPort, targetHost: "exact.direct.example", targetPort: 443)
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(
      fakeSS.connectionCount, beforeDirect,
      "自定义完整域名直连规则不得触达 Shadowsocks 出口")

    performSocksConnectReply(
      socksPort: listen.socksPort,
      request: socksIPv4ConnectRequest([203, 0, 113, 10], port: 443))
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(
      fakeSS.connectionCount, beforeDirect,
      "自定义 IPv4 CIDR 直连规则不得触达 Shadowsocks 出口")
  }

  /// 未匹配目标默认代理；HTTP 入站应用同一自定义规则 ACL。
  private func assertCustomUnmatchedProxies(
    listen: SslocalListenSettings, fakeSS: ConnectionCountingServer
  ) throws {
    let beforeHit = fakeSS.connectionCount
    performSocksConnectReply(
      socksPort: listen.socksPort, targetHost: "unmatched.example.org", targetPort: 443)
    XCTAssertTrue(
      try waitForCondition(timeout: 5) { fakeSS.connectionCount > beforeHit },
      "未匹配目标应走代理并连接 Shadowsocks 出口")

    let afterSocks = fakeSS.connectionCount
    performHTTPConnect(
      httpPort: listen.httpPort, targetHost: "other.direct.example", targetPort: 443)
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(
      fakeSS.connectionCount, afterSocks,
      "HTTP 入站的自定义直连规则不得触达 Shadowsocks 出口")

    performHTTPConnect(httpPort: listen.httpPort, targetHost: "8.8.8.8", targetPort: 53)
    XCTAssertTrue(
      try waitForCondition(timeout: 5) { fakeSS.connectionCount > afterSocks },
      "HTTP 入站未匹配目标应走代理")
  }

  /// 自定义规则真实 sslocal 路由（issue #66 AC4）：「未匹配时直连」下自定义
  /// 域名代理命中 SS 出口，未匹配目标直连。
  func testCustomRulesRouteOnSOCKSAndHTTPInDirectDefaultMode() throws {
    let echoServer = try LoopbackEchoServer()
    let fakeSSServer = try ConnectionCountingServer()
    let selectedPorts = try grabThreeListenPorts(excluding: [echoServer.port, fakeSSServer.port])
    let listen = SslocalListenSettings(
      socksPort: selectedPorts[0], httpPort: selectedPorts[1], pacPort: selectedPorts[2])
    let customSource = RuleSourceIdentity(
      kind: .custom, upstreamVersion: "user", label: "自定义")
    let customRules = [
      ProxyRule(
        action: .proxy, match: try RuleMatch(domainSuffix: "blocked.example"),
        source: customSource)
    ]
    let document = SslocalRuntimeDocument(
      servers: [
        SslocalServerDocument(
          id: "custom-direct-smoke-server",
          remarks: "custom-direct-smoke",
          server: "127.0.0.1",
          serverPort: fakeSSServer.port,
          password: "smoke-password",
          method: "aes-256-gcm",
          plugin: nil,
          pluginOpts: nil)
      ],
      listen: listen,
      acl: .rule(
        at: workDir.appendingPathComponent("sslocal-active.acl"),
        defaultAction: .directWhenUnmatched,
        rules: customRules))
    XCTAssertTrue(document.isWellFormed)
    let wrapper = try launchWrapper(document)
    defer {
      if wrapper.isRunning { kill(wrapper.processIdentifier, SIGTERM) }
    }

    try awaitGlobalInboundsReady(listen: listen, document: document)
    try assertCustomProxyCandidatesHitSS(listen: listen, fakeSS: fakeSSServer)

    stopWrapperAndAssertCleanExit(wrapper, description: "custom direct-default wrapper exits")
  }

  /// 自定义代理候选命中 SS；未匹配直连；HTTP 入站共用 ACL。
  private func assertCustomProxyCandidatesHitSS(
    listen: SslocalListenSettings, fakeSS: ConnectionCountingServer
  ) throws {
    let beforeHit = fakeSS.connectionCount
    performSocksConnectReply(
      socksPort: listen.socksPort, targetHost: "sub.blocked.example", targetPort: 443)
    XCTAssertTrue(
      try waitForCondition(timeout: 5) { fakeSS.connectionCount > beforeHit },
      "自定义代理候选应连接 Shadowsocks 出口")

    let afterHit = fakeSS.connectionCount
    performSocksConnectReply(
      socksPort: listen.socksPort, targetHost: "unmatched.example.org", targetPort: 443)
    Thread.sleep(forTimeInterval: 0.5)
    XCTAssertEqual(
      fakeSS.connectionCount, afterHit,
      "未匹配目标在 bypass_all 下应直连")

    performHTTPConnect(
      httpPort: listen.httpPort, targetHost: "cdn.blocked.example", targetPort: 443)
    XCTAssertTrue(
      try waitForCondition(timeout: 5) { fakeSS.connectionCount > afterHit },
      "HTTP 入站应应用同一自定义规则 ACL")
  }
}
