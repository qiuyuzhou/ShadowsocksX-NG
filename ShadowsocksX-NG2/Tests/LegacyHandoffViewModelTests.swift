import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// 交接视图模型（issue #37）：观察编排次序——确认门禁、执行前停 2.0、成功后
/// 启动 2.0、端口门禁失败不启动；确认按钮只对确有可停用内容且旧版 app 已退
/// 出的识别结果开放。
@MainActor
final class LegacyHandoffViewModelTests: XCTestCase {
  func testHappyPathStopsProxyHandsOffThenStartsProxy() async {
    let harness = makeHarness()

    await harness.model.refresh()
    XCTAssertTrue(harness.model.canConfirm)

    await harness.model.performHandoff()

    XCTAssertEqual(harness.model.phase, .completed)
    XCTAssertEqual(harness.events, [.stop, .start])
    XCTAssertTrue(harness.marker.completed)
    XCTAssertEqual(harness.model.report?.bootedOutLabels, ["com.qiuyuzhou.shadowsocksX-NG.local"])
    XCTAssertEqual(harness.model.handoffCompleted, true)
  }

  func testPortsNotReleasedFailsWithoutStartingProxy() async {
    let occupancy = FakeOccupancyProbe()
    occupancy.occupiers = [1086: "ss-local"]
    let harness = makeHarness(occupancy: occupancy)

    await harness.model.refresh()
    await harness.model.performHandoff()

    guard case .failed(let reason) = harness.model.phase else {
      return XCTFail("端口未释放应显式失败：\(harness.model.phase)")
    }
    XCTAssertTrue(reason.contains("端口未释放"))
    XCTAssertEqual(harness.events, [.stop])
    XCTAssertFalse(harness.marker.completed)
  }

  func testLegacyAppRunningBlocksConfirmation() async {
    let app = FakeLegacyAppController()
    app.running = true
    let harness = makeHarness(appController: app)

    await harness.model.refresh()

    XCTAssertFalse(harness.model.canConfirm)
    XCTAssertEqual(harness.events, [])
    await harness.model.performHandoff()
    XCTAssertEqual(harness.model.phase, .ready)
    XCTAssertEqual(harness.events, [])
  }

  func testConfirmationHiddenWhenNothingToStop() async {
    let launchctl = FakeLaunchctl()
    let harness = makeHarness(launchctl: launchctl)
    launchctl.loadedLabels = []

    await harness.model.refresh()

    XCTAssertFalse(harness.model.canConfirm)
    XCTAssertFalse(harness.model.hasUnknownState)
  }

  func testUnknownLaunchctlStateBlocksConfirmation() async {
    let launchctl = FakeLaunchctl()
    launchctl.printFailureDetail[LegacyLaunchAgentLabel.local.rawValue] = "launchctl: adhoc"
    let harness = makeHarness(launchctl: launchctl)

    await harness.model.refresh()

    XCTAssertFalse(harness.model.canConfirm)
    XCTAssertTrue(harness.model.hasUnknownState)
  }

  func testQuitLegacyAppRequestsQuitAndRedetects() async {
    let app = FakeLegacyAppController()
    app.running = true
    let harness = makeHarness(appController: app)

    await harness.model.refresh()
    XCTAssertFalse(harness.model.canConfirm)

    harness.model.quitLegacyApp()
    await Task.yield()

    XCTAssertTrue(app.quitRequested)
    XCTAssertFalse(app.running)
  }

  // MARK: - 夹具

  private func makeHarness(
    launchctl: FakeLaunchctl = FakeLaunchctl(),
    occupancy: FakeOccupancyProbe = FakeOccupancyProbe(),
    appController: FakeLegacyAppController = FakeLegacyAppController()
  ) -> Harness {
    let marker = FakeHandoffMarker()
    let service = LegacyHandoffService(
      launchctl: launchctl,
      plistInspector: FakePlistInspector(residues: []),
      appController: appController,
      portsProvider: FixedPortsProvider(),
      occupancyProbe: occupancy,
      proxyCleaner: FakeProxyCleaner(
        outcome: LegacyProxyCleanOutcome(cleanedServiceIDs: [], unknownOwnerServiceIDs: [])),
      marker: marker,
      portPollAttempts: 2,
      portPollIntervalNanoseconds: 1,
      removalVerifyAttempts: 2,
      removalVerifyIntervalNanoseconds: 1)
    launchctl.loadedLabels = [LegacyLaunchAgentLabel.local.rawValue]
    let model = LegacyHandoffViewModel(service: service, appController: appController)
    let harness = Harness(model: model, marker: marker, appController: appController)
    model.startProxy = { harness.events.append(.start) }
    model.stopProxy = { harness.events.append(.stop) }
    return harness
  }

  private final class Harness {
    let model: LegacyHandoffViewModel
    let marker: FakeHandoffMarker
    let appController: FakeLegacyAppController
    var events: [ProxyEvent] = []

    init(
      model: LegacyHandoffViewModel, marker: FakeHandoffMarker,
      appController: FakeLegacyAppController
    ) {
      self.model = model
      self.marker = marker
      self.appController = appController
    }
  }

  private enum ProxyEvent {
    case start
    case stop
  }
}
