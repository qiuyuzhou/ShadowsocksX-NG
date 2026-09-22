import XCTest

@testable import ShadowsocksX_NG2

/// 状态菜单八项白名单的纯呈现逻辑（spec #21 D11，issue #31）：头部状态摘要
/// 映射、HTTP 导出行派生、「切换模式」循环、活动目标级联树快照。
final class StatusMenuModelTests: XCTestCase {
  // MARK: - 头部状态摘要

  func testSummaryRunningStateIsOnWithNoDetail() {
    let summary = StatusMenuModel.summary(
      state: .running, mode: .pac, targetPath: "分组A / 香港 01")
    XCTAssertTrue(summary.isOn)
    XCTAssertEqual(summary.status, "代理运行中")
    XCTAssertNil(summary.detail)
  }

  func testSummaryOffStateIsOff() {
    let summary = StatusMenuModel.summary(state: .off, mode: .global, targetPath: nil)
    XCTAssertFalse(summary.isOn)
    XCTAssertEqual(summary.status, "代理未运行")
    XCTAssertNil(summary.detail)
  }

  func testSummaryFailureStatesCarryNamedDetail() {
    // 启动/激活失败：代理未在运行，开关意图为「启动」。
    for (state, expectedStatus) in [
      (ProxyRuntimeController.ProxyState.launchFailed(detail: "HTTP 端点未就绪"), "启动失败"),
      (.activationFailed(reason: "尚未激活任何服务器"), "无法启动"),
    ] {
      let summary = StatusMenuModel.summary(state: state, mode: .manual, targetPath: nil)
      XCTAssertFalse(summary.isOn)
      XCTAssertEqual(summary.status, expectedStatus)
      XCTAssertEqual(summary.detail, failureDetail(of: state))
    }
    // 系统代理失败：代理本体仍在运行，开关意图保持「停止」。
    let summary = StatusMenuModel.summary(
      state: .systemProxyFailed(detail: "系统代理写入失败"), mode: .manual, targetPath: nil)
    XCTAssertTrue(summary.isOn)
    XCTAssertEqual(summary.status, "系统代理未应用")
    XCTAssertEqual(summary.detail, "系统代理写入失败")
  }

  private func failureDetail(
    of state: ProxyRuntimeController.ProxyState
  ) -> String? {
    switch state {
    case .launchFailed(let detail), .activationFailed(let detail), .systemProxyFailed(let detail):
      return detail
    default:
      return nil
    }
  }

  func testSummaryCarriesModeLabelAndTargetPath() {
    let summary = StatusMenuModel.summary(
      state: .running, mode: .externalPAC(URL(string: "http://example.com/pac")!),
      targetPath: "订阅分组 / 嵌套分组 / 日本 02")
    XCTAssertEqual(summary.modeLabel, "外部 PAC")
    XCTAssertEqual(summary.targetPath, "订阅分组 / 嵌套分组 / 日本 02")
  }

  // MARK: - 复制 HTTP 导出行

  func testHTTPExportLineUsesLoopbackDefaults() {
    XCTAssertEqual(
      StatusMenuModel.httpExportLine(settings: SslocalListenSettings()),
      "export http_proxy=http://127.0.0.1:1087;export https_proxy=http://127.0.0.1:1087;")
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

  // MARK: - 全局快捷键「切换模式」循环

  func testNextModeCyclesBuiltinModes() {
    XCTAssertEqual(StatusMenuModel.nextMode(after: .pac), .global)
    XCTAssertEqual(StatusMenuModel.nextMode(after: .global), .manual)
    XCTAssertEqual(StatusMenuModel.nextMode(after: .manual), .pac)
  }

  func testNextModeFromExternalPACReturnsToPAC() {
    XCTAssertEqual(
      StatusMenuModel.nextMode(after: .externalPAC(URL(string: "http://example.com/pac")!)),
      .pac)
  }

  func testNextModeSkipsLegacyDisabledModes() {
    let enabledModes: Set<ProxyModeKind> = [.pac, .manual]

    XCTAssertEqual(
      StatusMenuModel.nextMode(after: .pac, availableModes: enabledModes),
      .manual)
    XCTAssertEqual(
      StatusMenuModel.nextMode(after: .manual, availableModes: enabledModes),
      .pac)
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
