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
      ],
      localAddress: "127.0.0.1",
      localPort: 1086,
      inboundProtocol: "socks",
      mode: "tcp_only"
    )
  }

  // MARK: 字段契约

  func testDocumentEncodesUpstreamContractKeys() throws {
    let dictionary = try encodedDictionary(
      makeDocument(plugin: "/bundle/plugins/x", pluginOpts: "obfs=http"))

    XCTAssertEqual(dictionary["local_address"] as? String, "127.0.0.1")
    XCTAssertEqual(dictionary["local_port"] as? Int, 1086)
    XCTAssertEqual(dictionary["protocol"] as? String, "socks")
    XCTAssertEqual(dictionary["mode"] as? String, "tcp_only")
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

  func testListenSettingsMapUDPRelayToUpstreamMode() {
    let tcpOnly = SslocalListenSettings(
      localAddress: "127.0.0.1", localPort: 1086, inboundProtocol: "socks", udpRelayEnabled: false)
    let tcpAndUDP = SslocalListenSettings(
      localAddress: "127.0.0.1", localPort: 1086, inboundProtocol: "socks", udpRelayEnabled: true)

    XCTAssertEqual(tcpOnly.mode, "tcp_only")
    XCTAssertEqual(tcpAndUDP.mode, "tcp_and_udp")
  }
}
