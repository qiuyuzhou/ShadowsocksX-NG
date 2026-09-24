import XCTest

@testable import ShadowsocksX_NG2

/// 运行时文档缝（spec #21 D5）：派生 JSON 的字段契约与监听设置透传。
/// 上游字段名以 shadowsocks-rust v1.25.0 配置契约为准（docs/research/
/// wayfinder-issue-2.md §2.2）；插件字段整体缺席语义见 D10。
final class RuntimeDocumentTests: XCTestCase {
  private func encodedDictionary(_ document: SslocalRuntimeDocument) throws -> [String: Any] {
    let data = try document.jsonData()
    let object = try JSONSerialization.jsonObject(with: data)
    return try XCTUnwrap(object as? [String: Any])
  }

  private func makeDocument(
    plugin: String? = nil, pluginOpts: String? = nil
  ) -> SslocalRuntimeDocument {
    SslocalRuntimeDocument(
      servers: [
        SslocalServerDocument(
          id: "server-1",
          remarks: "香港 01",
          server: "203.0.113.7",
          serverPort: 8388,
          password: "resolved-password",
          method: "aes-256-gcm",
          plugin: plugin,
          pluginOpts: pluginOpts
        )
      ], listen: SslocalListenSettings()
    )
  }

  // MARK: 字段契约

  func testDocumentEncodesUpstreamContractKeys() throws {
    let dictionary = try encodedDictionary(
      makeDocument(plugin: "/bundle/plugins/x", pluginOpts: "obfs=http"))

    let locals = try XCTUnwrap(dictionary["locals"] as? [[String: Any]])
    XCTAssertEqual(locals.count, 2)
    XCTAssertEqual(locals[0]["local_address"] as? String, "127.0.0.1")
    XCTAssertEqual(locals[0]["local_port"] as? Int, 11086)
    XCTAssertEqual(locals[0]["protocol"] as? String, "socks")
    XCTAssertEqual(locals[0]["mode"] as? String, "tcp_and_udp")
    XCTAssertEqual(locals[1]["local_port"] as? Int, 11087)
    XCTAssertEqual(locals[1]["protocol"] as? String, "http")
    let pac = try XCTUnwrap(dictionary["x_shadowsocksx_ng_pac"] as? [String: Any])
    XCTAssertEqual(pac["listen_scope"] as? String, "loopback")
    XCTAssertEqual(pac["port"] as? Int, 11089)
    let servers = try XCTUnwrap(dictionary["servers"] as? [[String: Any]])
    XCTAssertEqual(servers.count, 1)
    let server = servers[0]
    XCTAssertEqual(server["id"] as? String, "server-1", "叶子身份进入文档，供诊断与稳定标识")
    XCTAssertEqual(server["remarks"] as? String, "香港 01")
    XCTAssertEqual(server["server"] as? String, "203.0.113.7")
    XCTAssertEqual(server["server_port"] as? Int, 8388)
    XCTAssertEqual(server["password"] as? String, "resolved-password")
    XCTAssertEqual(server["method"] as? String, "aes-256-gcm")
    XCTAssertEqual(server["plugin"] as? String, "/bundle/plugins/x")
    XCTAssertEqual(server["plugin_opts"] as? String, "obfs=http")
  }

  func testPluginFieldsAreAbsentEntirelyWithoutPlugin() throws {
    let dictionary = try encodedDictionary(makeDocument())

    let server = try XCTUnwrap((dictionary["servers"] as? [[String: Any]])?[0])
    XCTAssertFalse(server.keys.contains("plugin"), "选「无」时 plugin 字段整体省略（D10）")
    XCTAssertFalse(server.keys.contains("plugin_opts"))
  }

  func testJSONDataIsStableAcrossEncodes() throws {
    let document = makeDocument(plugin: "/bundle/plugins/x")

    XCTAssertEqual(try document.jsonData(), try document.jsonData(), "编码确定性（sortedKeys）")
  }

  // MARK: 监听设置透传

  func testListenSettingsUseTCPAndUDPForSOCKSAndTCPOnlyForHTTP() {
    let listen = SslocalListenSettings()

    XCTAssertEqual(listen.mode, "tcp_and_udp")
    XCTAssertEqual(listen.locals.map(\.mode), ["tcp_and_udp", "tcp_only"])
  }

  func testRuntimeDocumentCarriesTimeoutVerboseAndPACUserRules() throws {
    let document = SslocalRuntimeDocument(
      servers: [
        SslocalServerDocument(
          id: "server-1", remarks: "test", server: "example.com", serverPort: 8388,
          password: "pw", method: "aes-256-gcm", plugin: nil, pluginOpts: nil)
      ],
      listen: SslocalListenSettings(),
      timeout: 120,
      verbose: true,
      pacUserRules: "@@||example.com^")

    let decoded = try XCTUnwrap(SslocalRuntimeDocument.decodeValidated(try document.jsonData()))

    XCTAssertEqual(decoded.timeout, 120)
    XCTAssertTrue(decoded.pac.verbose)
    XCTAssertTrue(decoded.pac.javaScript.contains("dnsDomainIs(host, \"example.com\")"))
    XCTAssertTrue(decoded.pac.javaScript.contains("DIRECT"))
  }

  func testLoopbackScopeDerivesPACAndBothSslocalInbounds() {
    let listen = SslocalListenSettings(
      scope: .loopback,
      socksPort: 1086,
      httpProxyEnabled: true,
      httpPort: 1087,
      pacPort: 1089)

    XCTAssertEqual(listen.bindAddress, "127.0.0.1")
    XCTAssertEqual(listen.advertisedAddress, "127.0.0.1")
    XCTAssertEqual(
      listen.locals,
      [
        SslocalLocalDocument(
          inboundProtocol: "socks", localAddress: "127.0.0.1", localPort: 1086,
          mode: "tcp_and_udp"),
        SslocalLocalDocument(
          inboundProtocol: "http", localAddress: "127.0.0.1", localPort: 1087,
          mode: "tcp_only"),
      ])
    XCTAssertEqual(listen.pac.port, 1089)
    XCTAssertEqual(listen.pac.endpointPath, "/v1/proxy.pac")
  }

  func testHostScopeUsesWildcardBindingsAndAdvertisedNetworkAddress() {
    let listen = SslocalListenSettings(
      scope: .host(advertisedAddress: "192.168.2.89"),
      socksPort: 1086,
      httpProxyEnabled: true,
      httpPort: 1087,
      pacPort: 1089)

    XCTAssertEqual(listen.bindAddress, "0.0.0.0")
    XCTAssertEqual(listen.advertisedAddress, "192.168.2.89")
    XCTAssertEqual(Set(listen.locals.map(\.localAddress)), ["0.0.0.0"])
    XCTAssertEqual(listen.pac.advertisedAddress, "192.168.2.89")
    XCTAssertEqual(
      listen.pac.javaScript,
      "function FindProxyForURL(url, host) { return \"SOCKS5 192.168.2.89:1086; SOCKS 192.168.2.89:1086; DIRECT\"; }\n"
    )
  }

  func testHTTPInboundCanBeDisabledWithoutChangingPACSOCKSTarget() {
    let listen = SslocalListenSettings(
      scope: .loopback, socksPort: 2086, httpProxyEnabled: false, httpPort: 2087,
      pacPort: 2089)

    XCTAssertEqual(listen.locals.map(\.inboundProtocol), ["socks"])
    XCTAssertTrue(listen.pac.javaScript.contains("127.0.0.1:2086"))
  }
}
