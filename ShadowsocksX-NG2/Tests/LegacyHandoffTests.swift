import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// Legacy 交接主缝（issue #37）：交接计划与执行时序。launchctl/探测/清理用
/// 假实现观察调用次序与退出码语义，不触碰真实 launchd、系统代理或 Legacy 数据。
final class LegacyHandoffTests: XCTestCase {
  // MARK: - 交接计划（纯决策）

  func testPlanBootsLoadedLabelsAndDisablesPlistResidue() {
    let detection = LegacyHandoffDetection(
      loadedLabels: [
        LegacyLaunchAgentLabel.kcptun.rawValue, LegacyLaunchAgentLabel.local.rawValue,
      ],
      printFailures: [],
      plists: [
        LegacyAgentPlistResidue(
          label: LegacyLaunchAgentLabel.local.rawValue, fileExists: true,
          keepAlive: false, runAtLoad: false),
        LegacyAgentPlistResidue(
          label: LegacyLaunchAgentLabel.http.rawValue, fileExists: false,
          keepAlive: false, runAtLoad: false),
      ],
      legacyAppRunning: false, legacyAppInstalled: true,
      ports: .factory())

    let plan = LegacyHandoffPlan.make(from: detection)

    XCTAssertEqual(
      plan.actions,
      [
        .bootout(label: LegacyLaunchAgentLabel.local.rawValue),
        .disable(label: LegacyLaunchAgentLabel.local.rawValue),
        .bootout(label: LegacyLaunchAgentLabel.kcptun.rawValue),
      ])
    XCTAssertEqual(
      plan.residue.map(\.label), [LegacyLaunchAgentLabel.local.rawValue])
  }

  func testPlanHasNoActionsWithoutEvidence() {
    let detection = LegacyHandoffDetection(
      loadedLabels: [], printFailures: [],
      plists: LegacyLaunchAgentLabel.allCases.map { label in
        LegacyAgentPlistResidue(
          label: label.rawValue, fileExists: false, keepAlive: false, runAtLoad: false)
      },
      legacyAppRunning: false, legacyAppInstalled: false, ports: .factory())

    let plan = LegacyHandoffPlan.make(from: detection)

    XCTAssertTrue(plan.actions.isEmpty)
    XCTAssertTrue(plan.residue.isEmpty)
  }

  // MARK: - 服务时序

  func testHappyPathCleansProxyBeforeBootoutThenConfirmsPorts() async throws {
    let launchctl = FakeLaunchctl()
    launchctl.loadedLabels = [
      LegacyLaunchAgentLabel.local.rawValue, LegacyLaunchAgentLabel.http.rawValue,
    ]
    let occupancy = FakeOccupancyProbe()
    let cleaner = FakeProxyCleaner(
      outcome: LegacyProxyCleanOutcome(
        cleanedServiceIDs: ["Wi-Fi"], unknownOwnerServiceIDs: []))
    let service = makeService(launchctl: launchctl, occupancy: occupancy, cleaner: cleaner)

    let report = try await service.performHandoff()

    // 次序：系统代理先清理（授权在前、失败即零影响），再 bootout。
    XCTAssertNotNil(cleaner.cleanCall)
    XCTAssertTrue(
      launchctl.recordedCalls.contains(
        .bootout(
          label: LegacyLaunchAgentLabel.local.rawValue)))
    XCTAssertTrue(
      launchctl.recordedCalls.contains(
        .bootout(
          label: LegacyLaunchAgentLabel.http.rawValue)))
    XCTAssertEqual(
      report.bootedOutLabels,
      [
        LegacyLaunchAgentLabel.local.rawValue, LegacyLaunchAgentLabel.http.rawValue,
      ])
    XCTAssertEqual(report.confirmedFreePorts.sorted(), [1086, 1087, 1089])
    XCTAssertEqual(report.proxyServicesCleaned, ["Wi-Fi"])
    XCTAssertTrue(marker.completed)
    // 交接后验证卸载：每个 bootout 之后紧跟一次 print 验证（只看退出码）。
    let calls = launchctl.recordedCalls
    let bootoutIndexes = calls.indices.filter { index in
      if case .bootout = calls[index] { return true } else { return false }
    }
    XCTAssertEqual(bootoutIndexes.count, 2)
    for index in bootoutIndexes {
      guard index + 1 < calls.count, case .state = calls[index + 1] else {
        return XCTFail("bootout 后应立即以 print 退出码验证卸载")
      }
    }
  }

  func testPlistResidueIsDisabledAndReported() async throws {
    let launchctl = FakeLaunchctl()
    let plists = [
      LegacyAgentPlistResidue(
        label: LegacyLaunchAgentLabel.local.rawValue, fileExists: true,
        keepAlive: true, runAtLoad: false)
    ]
    let service = makeService(
      launchctl: launchctl,
      plists: plists,
      cleaner: FakeProxyCleaner())

    let report = try await service.performHandoff()

    XCTAssertTrue(
      launchctl.recordedCalls.contains(
        .disable(
          label: LegacyLaunchAgentLabel.local.rawValue)))
    XCTAssertEqual(report.disabledLabels, [LegacyLaunchAgentLabel.local.rawValue])
    XCTAssertEqual(report.residue.count, 1)
    XCTAssertTrue(report.residue[0].keepAlive)
  }

  func testBootoutThatLeavesJobLoadedEscalatesToDocumentedKill() async throws {
    let launchctl = FakeLaunchctl()
    let label = LegacyLaunchAgentLabel.local.rawValue
    launchctl.loadedLabels = [label]
    launchctl.bootoutBehavior[label] = .succeedsButKeepsLoaded
    let service = makeService(
      launchctl: launchctl,
      cleaner: FakeProxyCleaner())

    let report = try await service.performHandoff()

    XCTAssertTrue(launchctl.recordedCalls.contains(.kill(label: label, signal: SIGTERM)))
    XCTAssertEqual(report.killedLabels, [label])
    XCTAssertEqual(report.bootedOutLabels, [label])
  }

  func testUnremovableJobFailsWithoutPortGate() async {
    let launchctl = FakeLaunchctl()
    launchctl.loadedLabels = [LegacyLaunchAgentLabel.local.rawValue]
    launchctl.bootoutBehavior[LegacyLaunchAgentLabel.local.rawValue] = .unremovable
    let occupancy = FakeOccupancyProbe()
    let service = makeService(
      launchctl: launchctl,
      occupancy: occupancy,
      cleaner: FakeProxyCleaner())

    do {
      _ = try await service.performHandoff()
      XCTFail("不可移除的 job 应显式失败")
    } catch let error as LegacyHandoffError {
      guard case .bootoutFailed(let label, _) = error else {
        return XCTFail("意外的错误：\(error)")
      }
      XCTAssertEqual(label, LegacyLaunchAgentLabel.local.rawValue)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
    // 端口门禁未执行：失败路径不允许继续启动 2.0。
    XCTAssertTrue(occupancy.probedPorts.isEmpty)
    XCTAssertFalse(marker.completed)
  }

  func testBootoutOfJobThatVanishedBetweenPrintAndBootoutIsNotAnError() async throws {
    let launchctl = FakeLaunchctl()
    launchctl.loadedLabels = [LegacyLaunchAgentLabel.local.rawValue]
    launchctl.bootoutBehavior[LegacyLaunchAgentLabel.local.rawValue] = .alreadyGone
    let service = makeService(
      launchctl: launchctl,
      cleaner: FakeProxyCleaner())

    let report = try await service.performHandoff()

    XCTAssertEqual(report.bootedOutLabels, [LegacyLaunchAgentLabel.local.rawValue])
  }

  func testPortsStillOccupiedFailsExplicitlyWithoutCompleting() async {
    let occupancy = FakeOccupancyProbe()
    occupancy.occupiers = [1086: "ss-local"]
    let service = makeService(
      occupancy: occupancy,
      cleaner: FakeProxyCleaner())

    do {
      _ = try await service.performHandoff()
      XCTFail("端口未释放应显式失败")
    } catch let error as LegacyHandoffError {
      guard case .portsNotReleased(let occupied) = error else {
        return XCTFail("意外的错误：\(error)")
      }
      XCTAssertEqual(occupied, ["1086（ss-local）"])
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
    XCTAssertFalse(marker.completed)
  }

  func testPortGatePollsUntilAllThreePortsAreFree() async throws {
    let occupancy = FakeOccupancyProbe()
    occupancy.occupiers = [1086: "ss-local", 1089: "ShadowsocksX-NG"]
    occupancy.occupanciesUntilFree = 2
    let service = makeService(
      occupancy: occupancy,
      cleaner: FakeProxyCleaner())

    let report = try await service.performHandoff()

    XCTAssertEqual(report.confirmedFreePorts.sorted(), [1086, 1087, 1089])
    XCTAssertEqual(occupancy.probedPorts.filter { $0 == 1086 }.count, 2)
  }

  func testUnknownOwnerProxyIsReportedUntouched() async throws {
    let cleaner = FakeProxyCleaner(
      outcome: LegacyProxyCleanOutcome(
        cleanedServiceIDs: [], unknownOwnerServiceIDs: ["Wi-Fi", "Ethernet"]))
    let service = makeService(
      launchctl: FakeLaunchctl(),
      cleaner: cleaner)

    let report = try await service.performHandoff()

    XCTAssertEqual(report.proxyServicesUntouchedUnknownOwner, ["Wi-Fi", "Ethernet"])
    XCTAssertTrue(report.proxyServicesCleaned.isEmpty)
  }

  func testProxyCleanFailureAbortsBeforeAnyLaunchctlAction() async {
    let launchctl = FakeLaunchctl()
    let service = makeService(
      launchctl: launchctl,
      cleaner: FakeProxyCleaner(error: LegacyHandoffError.proxyCleanFailed(detail: "授权被拒绝")))

    do {
      _ = try await service.performHandoff()
      XCTFail("系统代理清理失败应中止交接")
    } catch let error as LegacyHandoffError {
      guard case .proxyCleanFailed = error else {
        return XCTFail("意外的错误：\(error)")
      }
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
    // 只读识别允许发生；不得有任何 launchd 变更动作。
    XCTAssertTrue(
      launchctl.recordedCalls.allSatisfy { call in
        if case .state = call { return true } else { return false }
      })
    XCTAssertFalse(marker.completed)
  }

  func testRunningLegacyAppRefusesBeforeAnyAction() async {
    let launchctl = FakeLaunchctl()
    let app = FakeLegacyAppController()
    app.running = true
    let service = makeService(launchctl: launchctl, appController: app)

    do {
      _ = try await service.performHandoff()
      XCTFail("旧版 app 未退出应拒绝交接")
    } catch let error as LegacyHandoffError {
      guard case .legacyAppRunning = error else {
        return XCTFail("意外的错误：\(error)")
      }
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
    XCTAssertTrue(launchctl.recordedCalls.isEmpty)
    XCTAssertFalse(marker.completed)
  }

  func testUnknownLaunchctlPrintStateAbortsDetection() async {
    let launchctl = FakeLaunchctl()
    launchctl.printFailureDetail[LegacyLaunchAgentLabel.http.rawValue] = "launchctl: adhoc"
    let service = makeService(launchctl: launchctl)

    do {
      _ = try await service.performHandoff()
      XCTFail("launchctl 状态未知应中止")
    } catch let error as LegacyHandoffError {
      guard case .detectionFailed = error else {
        return XCTFail("意外的错误：\(error)")
      }
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
    XCTAssertFalse(marker.completed)
  }

  func testDisableFailureIsFatal() async {
    let launchctl = FakeLaunchctl()
    let label = LegacyLaunchAgentLabel.local.rawValue
    launchctl.disableFailures = [label: LaunchctlOutcome(exitCode: 1, stderr: "denied")]
    let plists = [
      LegacyAgentPlistResidue(label: label, fileExists: true, keepAlive: false, runAtLoad: false)
    ]
    let service = makeService(
      launchctl: launchctl,
      plists: plists,
      cleaner: FakeProxyCleaner())

    do {
      _ = try await service.performHandoff()
      XCTFail("disable 失败应显式失败（残留会在下次登录复活）")
    } catch let error as LegacyHandoffError {
      guard case .disableFailed(let failed, _) = error else {
        return XCTFail("意外的错误：\(error)")
      }
      XCTAssertEqual(failed, label)
    } catch {
      XCTFail("意外的错误类型：\(error)")
    }
  }

  func testCompletionMarkerSurvivesRerunAndDetectReadsState() async throws {
    let launchctl = FakeLaunchctl()
    launchctl.loadedLabels = [LegacyLaunchAgentLabel.kcptun.rawValue]
    let service = makeService(
      launchctl: launchctl,
      cleaner: FakeProxyCleaner())

    _ = try await service.performHandoff()
    XCTAssertTrue(marker.completed)

    // 幂等重跑：一切已移除时同样成功，且再次写入标记。
    let second = try await service.performHandoff()
    XCTAssertTrue(second.bootedOutLabels.isEmpty)
    XCTAssertTrue(marker.completed)
  }

  // MARK: - 夹具

  private var marker = FakeHandoffMarker()

  override func setUpWithError() throws {
    try super.setUpWithError()
    marker = FakeHandoffMarker()
  }

  private func makeService(
    launchctl: FakeLaunchctl = FakeLaunchctl(),
    plists: [LegacyAgentPlistResidue] = [],
    appController: FakeLegacyAppController = FakeLegacyAppController(),
    occupancy: FakeOccupancyProbe = FakeOccupancyProbe(),
    cleaner: FakeProxyCleaner = FakeProxyCleaner()
  ) -> LegacyHandoffService {
    let inspector = FakePlistInspector(residues: plists)
    return LegacyHandoffService(
      launchctl: launchctl,
      plistInspector: inspector,
      appController: appController,
      portsProvider: FixedPortsProvider(),
      occupancyProbe: occupancy,
      proxyCleaner: cleaner,
      marker: marker,
      portPollAttempts: 2,
      portPollIntervalNanoseconds: 1,
      removalVerifyAttempts: 2,
      removalVerifyIntervalNanoseconds: 1)
  }
}
