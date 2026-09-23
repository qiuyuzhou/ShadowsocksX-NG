import XCTest

@testable import ShadowsocksX_NG2

/// 状态菜单八项白名单的纯呈现逻辑（spec #21 D11，issue #31）：头部状态摘要
/// 映射、HTTP 导出行派生、「切换模式」循环、活动目标级联树快照。
final class StatusMenuModelTests: XCTestCase {
  private struct RuntimeSummaryCase {
    let facts: ProxyRuntimeFacts
    let expectedStatus: String
    let expectedIsOn: Bool
  }

  private static let runtimeSummaryCases: [RuntimeSummaryCase] = [
    RuntimeSummaryCase(
      facts: ProxyRuntimeFacts(status: .starting, isOn: true),
      expectedStatus: "正在启动代理…",
      expectedIsOn: true),
    RuntimeSummaryCase(
      facts: ProxyRuntimeFacts(status: .running, isOn: true),
      expectedStatus: "代理运行中",
      expectedIsOn: true),
    RuntimeSummaryCase(
      facts: ProxyRuntimeFacts(
        status: .firewallBlocked,
        isOn: true,
        failure: .firewallBlocked(FirewallBlockedFacts(executableName: "sslocal"))),
      expectedStatus: "代理运行中（局域网受阻）",
      expectedIsOn: true),
    RuntimeSummaryCase(
      facts: ProxyRuntimeFacts(
        status: .launchFailed,
        isOn: false,
        failure: .launch(
          .localEndpoint(
            endpoint: "http", host: "127.0.0.1", port: 11087, cause: .refused))),
      expectedStatus: "启动失败",
      expectedIsOn: false),
    RuntimeSummaryCase(
      facts: ProxyRuntimeFacts(
        status: .activationFailed,
        isOn: false,
        failure: .activation(.noActiveTarget)),
      expectedStatus: "无法启动",
      expectedIsOn: false),
    RuntimeSummaryCase(
      facts: ProxyRuntimeFacts(
        status: .requiresApproval, isOn: true, failure: .requiresApproval),
      expectedStatus: "等待允许后台代理",
      expectedIsOn: true),
    RuntimeSummaryCase(
      facts: ProxyRuntimeFacts(
        status: .serviceFailed,
        isOn: false,
        failure: .service(.persistence)),
      expectedStatus: "服务管理失败",
      expectedIsOn: false),
    RuntimeSummaryCase(
      facts: ProxyRuntimeFacts(
        status: .systemProxyFailed,
        isOn: true,
        failure: .systemProxy(.operation(.applyFailed))),
      expectedStatus: "系统代理未应用",
      expectedIsOn: true),
  ]

  // MARK: - 头部状态摘要

  func testSummaryRunningStateIsOnWithNoDetail() {
    let summary = StatusMenuModel.summary(
      facts: ProxyRuntimeFacts(status: .running, isOn: true),
      mode: .pac,
      targetPath: "分组A / 香港 01")
    XCTAssertTrue(summary.isOn)
    XCTAssertEqual(summary.status, "代理运行中")
    XCTAssertNil(summary.detail)
  }

  func testSummaryOffStateIsOff() {
    let summary = StatusMenuModel.summary(
      facts: ProxyRuntimeFacts(status: .off, isOn: false), mode: .global, targetPath: nil)
    XCTAssertFalse(summary.isOn)
    XCTAssertEqual(summary.status, "代理未运行")
    XCTAssertNil(summary.detail)
  }

  func testSummaryProjectsEveryStableRuntimeStatus() {
    for testCase in Self.runtimeSummaryCases {
      let summary = StatusMenuModel.summary(
        facts: testCase.facts, mode: .pac, targetPath: nil)
      XCTAssertEqual(summary.isOn, testCase.expectedIsOn)
      XCTAssertEqual(summary.status, testCase.expectedStatus)
      XCTAssertEqual(
        summary.detail,
        testCase.facts.failure.map { AppPresentation.message(for: $0) })
    }
  }

  func testSummaryCarriesModeLabelAndTargetPath() {
    let summary = StatusMenuModel.summary(
      facts: ProxyRuntimeFacts(status: .running, isOn: true),
      mode: .global,
      targetPath: "订阅分组 / 嵌套分组 / 日本 02")
    XCTAssertEqual(summary.modeLabel, "全局")
    XCTAssertEqual(summary.targetPath, "订阅分组 / 嵌套分组 / 日本 02")
  }

  // MARK: - 复制 HTTP 导出行

  func testHTTPExportLineUsesLoopbackDefaults() {
    XCTAssertEqual(
      StatusMenuModel.httpExportLine(settings: SslocalListenSettings()),
      "export http_proxy=http://127.0.0.1:11087;export https_proxy=http://127.0.0.1:11087;")
  }

  func testHTTPExportLineUsesAdvertisedAddressAndPortInHostScope() {
    var settings = SslocalListenSettings()
    settings.scope = .host(advertisedAddress: "192.168.1.10")
    settings.httpPort = 8080
    XCTAssertEqual(
      StatusMenuModel.httpExportLine(settings: settings),
      "export http_proxy=http://192.168.1.10:8080;export https_proxy=http://192.168.1.10:8080;")
  }

  func testHTTPExportLineUnavailableWhenHTTPInboundDisabled() {
    var settings = SslocalListenSettings()
    settings.httpProxyEnabled = false
    XCTAssertNil(StatusMenuModel.httpExportLine(settings: settings))
  }

  // MARK: - 活动目标路径（目录树 projection 派生，issue #41）

  /// 目录树 projection 构建夹具（同工作流 module 的推导路径）。
  private func makeTree(from catalog: ConfigurationCatalog) -> CatalogTreeSnapshot {
    CatalogTreeSnapshot.build(
      from: catalog, credentials: InMemoryCredentialStore(),
      plugins: NoManagedPluginProvider())
  }

  func testTargetPathResolvesThroughTreeProjection() throws {
    let fixture = try CatalogFixtures.makeSubscriptionFixture()
    let tree = makeTree(from: fixture.catalog)
    XCTAssertEqual(tree.roots.count, 1)
    XCTAssertEqual(
      StatusMenuModel.targetPath(in: tree.roots, activeTargetID: fixture.serverIDs[0]),
      "订阅分组 / 香港 01")
    XCTAssertEqual(
      StatusMenuModel.targetPath(in: tree.roots, activeTargetID: fixture.serverIDs[1]),
      "订阅分组 / 嵌套分组 / 日本 02")
  }

  func testTargetPathMarksGroupTargetAndAddressFallback() throws {
    var catalog = ConfigurationCatalog()
    let serverID = NodeID(rawValue: "manual:server")
    try catalog.addServer(CatalogFixtures.serverFields(remark: ""), id: serverID)
    let groupID = NodeID(rawValue: "manual:group")
    try catalog.addGroup("本地分组", id: groupID)
    let tree = makeTree(from: catalog)
    XCTAssertEqual(
      StatusMenuModel.targetPath(in: tree.roots, activeTargetID: groupID), "本地分组")
    XCTAssertEqual(
      StatusMenuModel.targetPath(in: tree.roots, activeTargetID: serverID), "203.0.113.7")
  }

  func testTargetPathNilWhenAbsentOrMissing() throws {
    let fixture = try CatalogFixtures.makeSubscriptionFixture()
    let tree = makeTree(from: fixture.catalog)
    XCTAssertNil(StatusMenuModel.targetPath(in: tree.roots, activeTargetID: nil))
    XCTAssertNil(
      StatusMenuModel.targetPath(in: tree.roots, activeTargetID: NodeID(rawValue: "gone")),
      "目标已不在树中为 nil")
  }
}
