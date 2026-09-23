import XCTest

@testable import ShadowsocksX_NG2

/// 状态菜单八项白名单的纯呈现逻辑（spec #21 D11，issue #31/#47）：头部状态
/// 摘要从代理控制工作流的整体 snapshot 派生。不持有 AppKit 类型；HTTP 导出
/// 行与目标路径摘要分别在代理控制与目录 module 测试覆盖。
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

  /// 从运行时事实构造最小 snapshot（其余字段与本组用例无关）。
  private func makeSnapshot(
    facts: ProxyRuntimeFacts,
    mode: ProxyMode = .pac,
    activeTarget: ProxyActiveTargetFacts? = nil
  ) -> ProxyControlSnapshot {
    ProxyControlSnapshot(
      runtime: facts,
      proxyMode: mode,
      availableModes: ProxyMode.availableModes,
      activeTarget: activeTarget,
      skippedInvalidServerCount: 0,
      httpExport: nil)
  }

  // MARK: - 头部状态摘要

  func testSummaryRunningStateIsOnWithNoDetail() {
    let summary = StatusMenuModel.summary(
      from: makeSnapshot(facts: ProxyRuntimeFacts(status: .running, isOn: true)))
    XCTAssertTrue(summary.isOn)
    XCTAssertEqual(summary.status, "代理运行中")
    XCTAssertNil(summary.detail)
  }

  func testSummaryOffStateIsOff() {
    let summary = StatusMenuModel.summary(
      from: makeSnapshot(facts: ProxyRuntimeFacts(status: .off, isOn: false), mode: .global))
    XCTAssertFalse(summary.isOn)
    XCTAssertEqual(summary.status, "代理未运行")
    XCTAssertNil(summary.detail)
  }

  func testSummaryProjectsEveryStableRuntimeStatus() {
    for testCase in Self.runtimeSummaryCases {
      let summary = StatusMenuModel.summary(from: makeSnapshot(facts: testCase.facts))
      XCTAssertEqual(summary.isOn, testCase.expectedIsOn)
      XCTAssertEqual(summary.status, testCase.expectedStatus)
      XCTAssertEqual(
        summary.detail,
        testCase.facts.failure.map { AppPresentation.message(for: $0) })
    }
  }

  func testSummaryCarriesModeLabelAndTargetPathFromSnapshot() {
    let summary = StatusMenuModel.summary(
      from: makeSnapshot(
        facts: ProxyRuntimeFacts(status: .running, isOn: true),
        mode: .global,
        activeTarget: ProxyActiveTargetFacts(
          id: NodeID(rawValue: "manual:server"), pathSummary: "订阅分组 / 嵌套分组 / 日本 02")))
    XCTAssertEqual(summary.modeLabel, "全局")
    XCTAssertEqual(summary.targetPath, "订阅分组 / 嵌套分组 / 日本 02")
  }

  func testSummaryTargetPathIsNilWithoutActiveTarget() {
    let summary = StatusMenuModel.summary(
      from: makeSnapshot(facts: ProxyRuntimeFacts(status: .off, isOn: false)))
    XCTAssertNil(summary.targetPath)
  }
}
