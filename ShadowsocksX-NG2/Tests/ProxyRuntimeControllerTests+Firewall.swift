import Combine
import XCTest

@testable import ShadowsocksX_NG2

extension ProxyRuntimeControllerTests {
  func testLoopbackScopeNeverQueriesApplicationFirewallAndPublishesPACURL() async throws {
    let seeded = try makeSeededCatalog()
    let firewall = ProxyRuntimeFixture.FakeFirewallChecker(.blocked)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), firewallChecker: firewall)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    XCTAssertEqual(controller.state, .running)
    XCTAssertTrue(firewall.checkedURLs.isEmpty, "回环态与应用防火墙零交互")
    XCTAssertEqual(controller.pacURL?.absoluteString, "http://127.0.0.1:11089/v1/proxy.pac")
  }

  func testHostScopeBlockedByFirewallPresentsTargetedRepairAndKeepsPACURL() async throws {
    let seeded = try makeSeededCatalog()
    let firewall = ProxyRuntimeFixture.FakeFirewallChecker(.blocked)
    let listen = SslocalListenSettings(
      scope: .host(advertisedAddress: "192.168.2.89"),
      socksPort: 1086,
      httpPort: 1087,
      pacPort: 1089)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      listen: listen,
      firewallChecker: firewall)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    guard case .firewallBlocked(let facts) = controller.state else {
      XCTFail("主机态被拒应呈现防火墙状态，实际 \(controller.state)")
      return
    }
    XCTAssertEqual(facts.executableName, "sslocal")
    XCTAssertTrue(AppPresentation.message(for: controller.state).contains("允许传入连接"))
    XCTAssertEqual(firewall.checkedURLs.map(\.lastPathComponent), ["sslocal"])
    XCTAssertEqual(controller.pacURL?.absoluteString, "http://192.168.2.89:1089/v1/proxy.pac")
  }

  func testHostScopeDetectsFirewallRefusalAfterInitialHealthyPresentation() async throws {
    let seeded = try makeSeededCatalog()
    let firewall = ProxyRuntimeFixture.FakeFirewallChecker(outcomes: [.permitted, .blocked])
    let listen = SslocalListenSettings(scope: .host(advertisedAddress: "192.168.2.89"))
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      listen: listen,
      firewallChecker: firewall)

    try await controller.activate(seeded.server)
    await controller.setAgentEnabled(true)

    let deadline = Date().addingTimeInterval(1)
    while controller.state == .running && Date() < deadline {
      try await Task.sleep(nanoseconds: 5_000_000)
    }
    guard case .firewallBlocked(let facts) = controller.state else {
      XCTFail("稍后发生的拒绝也必须被检测，实际 \(controller.state)")
      return
    }
    XCTAssertEqual(facts.executableName, "sslocal")
    XCTAssertTrue(AppPresentation.message(for: controller.state).contains("允许传入连接"))
    XCTAssertGreaterThanOrEqual(firewall.checkedURLs.count, 2)
  }
}
