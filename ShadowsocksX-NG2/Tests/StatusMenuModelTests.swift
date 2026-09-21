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

  // MARK: - 活动目标级联树（只读）

  func testTargetTreeMirrorsCatalogStructureAndMarksActiveServer() throws {
    let fixture = try CatalogFixtures.makeSubscriptionFixture()
    let tree = StatusMenuModel.targetTree(
      catalog: fixture.catalog, activeTargetID: fixture.serverIDs[0])
    XCTAssertEqual(tree.count, 1)
    let group = tree[0]
    XCTAssertEqual(group.name, "订阅分组")
    XCTAssertTrue(group.isGroup)
    XCTAssertFalse(group.isActive)
    XCTAssertEqual(group.children.count, 2)
    XCTAssertEqual(group.children[0].name, "嵌套分组")
    XCTAssertTrue(group.children[0].isGroup)
    XCTAssertEqual(group.children[0].children.count, 1)
    XCTAssertEqual(group.children[0].children[0].name, "日本 02")
    XCTAssertFalse(group.children[0].children[0].isActive)
    XCTAssertEqual(group.children[1].name, "香港 01")
    XCTAssertFalse(group.children[1].isGroup)
    XCTAssertTrue(group.children[1].isActive)
  }

  func testTargetTreeMarksActiveGroupAndServerNameFallsBackToAddress() throws {
    var catalog = ConfigurationCatalog()
    let serverID = NodeID(rawValue: "manual:server")
    try catalog.addServer(CatalogFixtures.serverFields(remark: ""), id: serverID)
    let groupID = NodeID(rawValue: "manual:group")
    try catalog.addGroup("本地分组", id: groupID)
    let tree = StatusMenuModel.targetTree(catalog: catalog, activeTargetID: groupID)
    XCTAssertEqual(tree.count, 2)
    XCTAssertEqual(tree[0].name, "203.0.113.7")
    XCTAssertFalse(tree[0].isActive)
    XCTAssertEqual(tree[1].name, "本地分组")
    XCTAssertTrue(tree[1].isActive)
  }

  func testTargetTreeEmptyCatalogYieldsEmptyTree() {
    XCTAssertTrue(
      StatusMenuModel.targetTree(catalog: ConfigurationCatalog(), activeTargetID: nil).isEmpty)
  }
}
