import Combine
import XCTest

@testable import ShadowsocksX_NG2

// MARK: - 确定性替身（snapshot 与命令 contract；不触真实运行时）

/// 可编程 runtime 替身（issue #47，story 31）：事实可编程、命令全记录；
/// changes 为手动 subject，同步发值保证观察测试确定性。
@MainActor
private final class FakeProxyRuntime: ProxyRuntimeAdapting {
  var runtimeFacts: ProxyRuntimeFacts
  var proxyMode: ProxyMode
  var skippedInvalidServerCount = 0
  var activeTargetID: NodeID?
  var httpExportCapability = HTTPExportCapability(
    copyableLine:
      "export http_proxy=http://127.0.0.1:11087;export https_proxy=http://127.0.0.1:11087;")

  private let changeSubject = PassthroughSubject<Void, Never>()
  var changes: AnyPublisher<Void, Never> { changeSubject.eraseToAnyPublisher() }

  private(set) var resyncCount = 0
  private(set) var enabledCommands: [Bool] = []
  private(set) var modeCommands: [ProxyMode] = []

  init(
    facts: ProxyRuntimeFacts = ProxyRuntimeFacts(status: .off, isOn: false),
    mode: ProxyMode = .pac
  ) {
    runtimeFacts = facts
    proxyMode = mode
  }

  func emitChange() { changeSubject.send() }

  func resyncOnLaunch() async { resyncCount += 1 }

  func setProxyEnabled(_ enabled: Bool) async { enabledCommands.append(enabled) }

  func setProxyMode(_ mode: ProxyMode) async { modeCommands.append(mode) }
}

/// 可编程目标事实替身（story 32）：路径摘要可编程、查询全记录。
@MainActor
private final class FakeTargetFacts: ProxyTargetFactsReading {
  var pathByTarget: [NodeID: String] = [:]
  private(set) var queriedTargetIDs: [NodeID?] = []

  func activeTargetFacts(for targetID: NodeID?) -> ProxyActiveTargetFacts? {
    queriedTargetIDs.append(targetID)
    guard let targetID else { return nil }
    return ProxyActiveTargetFacts(id: targetID, pathSummary: pathByTarget[targetID])
  }
}

/// 代理控制工作流的 snapshot 与命令 contract（issue #47）：整体一致性、
/// typed commands、窄目录事实缝、运行时变化重观察与命令边界。
@MainActor
final class ProxyControlWorkflowTests: XCTestCase {
  private var runtime: FakeProxyRuntime!
  private var targetFacts: FakeTargetFacts!
  private var workflow: ProxyControlWorkflow!

  override func setUp() {
    super.setUp()
    runtime = FakeProxyRuntime()
    targetFacts = FakeTargetFacts()
    workflow = ProxyControlWorkflow(runtime: runtime, targetFacts: targetFacts)
  }

  private static let serverID = NodeID(rawValue: "manual:server-1")

  private func makeSnapshot(
    facts: ProxyRuntimeFacts,
    mode: ProxyMode,
    activeTarget: ProxyActiveTargetFacts?,
    skipped: Int,
    export: HTTPExportCapability
  ) -> ProxyControlSnapshot {
    ProxyControlSnapshot(
      runtime: facts,
      proxyMode: mode,
      availableModes: ProxyMode.availableModes,
      activeTarget: activeTarget,
      skippedInvalidServerCount: skipped,
      httpExport: export)
  }

  // MARK: - 整体 snapshot

  func testSnapshotAssemblesAllFactsFromSingleObservation() {
    runtime.runtimeFacts = ProxyRuntimeFacts(
      status: .running,
      isOn: true,
      failure: .firewallBlocked(FirewallBlockedFacts(executableName: "sslocal")))
    runtime.proxyMode = .global
    runtime.skippedInvalidServerCount = 3
    runtime.activeTargetID = Self.serverID
    runtime.httpExportCapability = HTTPExportCapability(
      copyableLine: "export http_proxy=http://127.0.0.1:11087;")
    targetFacts.pathByTarget[Self.serverID] = "组A / 香港 01"
    runtime.emitChange()

    XCTAssertEqual(
      workflow.snapshot,
      makeSnapshot(
        facts: ProxyRuntimeFacts(
          status: .running,
          isOn: true,
          failure: .firewallBlocked(FirewallBlockedFacts(executableName: "sslocal"))),
        mode: .global,
        activeTarget: ProxyActiveTargetFacts(id: Self.serverID, pathSummary: "组A / 香港 01"),
        skipped: 3,
        export: HTTPExportCapability(copyableLine: "export http_proxy=http://127.0.0.1:11087;")))
    XCTAssertEqual(
      workflow.snapshot.availableModes, ProxyMode.availableModes,
      "可用模式是 issue #46 Domain 单点策略的投影")
  }

  // MARK: - typed commands：转发并整体重发布

  func testEnableCommandForwardsAndRepublishesWholeSnapshot() async {
    let before = workflow.snapshot
    runtime.runtimeFacts = ProxyRuntimeFacts(status: .running, isOn: true)
    runtime.skippedInvalidServerCount = 2
    runtime.activeTargetID = Self.serverID

    let after = await workflow.setProxyEnabled(true)

    XCTAssertEqual(runtime.enabledCommands, [true])
    XCTAssertEqual(after, workflow.snapshot, "命令返回值就是已发布的最新 snapshot")
    XCTAssertNotEqual(after, before, "命令完成后整体重发布")
    XCTAssertEqual(after.runtime, ProxyRuntimeFacts(status: .running, isOn: true))
    XCTAssertEqual(after.skippedInvalidServerCount, 2)
  }

  func testDisableCommandForwardsAndRepublishesWholeSnapshot() async {
    runtime.runtimeFacts = ProxyRuntimeFacts(status: .running, isOn: true)
    _ = await workflow.setProxyEnabled(true)
    runtime.runtimeFacts = ProxyRuntimeFacts(status: .off, isOn: false)
    runtime.skippedInvalidServerCount = 0
    runtime.activeTargetID = nil

    let after = await workflow.setProxyEnabled(false)

    XCTAssertEqual(runtime.enabledCommands, [true, false])
    XCTAssertEqual(after.runtime, ProxyRuntimeFacts(status: .off, isOn: false))
    XCTAssertNil(after.activeTarget)
  }

  func testModeCommandForwardsAndRepublishesWholeSnapshot() async {
    runtime.runtimeFacts = ProxyRuntimeFacts(status: .running, isOn: true)
    _ = await workflow.setProxyEnabled(true)
    runtime.proxyMode = .global

    let after = await workflow.setProxyMode(.global)

    XCTAssertEqual(runtime.modeCommands, [.global])
    XCTAssertEqual(after.proxyMode, .global)
    XCTAssertEqual(after.runtime, ProxyRuntimeFacts(status: .running, isOn: true))
  }

  func testResyncOnLaunchForwardsAndRepublishes() async {
    let before = workflow.snapshot
    runtime.runtimeFacts = ProxyRuntimeFacts(
      status: .running, isOn: true, failure: nil)

    await workflow.resyncOnLaunch()

    XCTAssertEqual(runtime.resyncCount, 1)
    XCTAssertNotEqual(workflow.snapshot, before)
    XCTAssertEqual(workflow.snapshot.runtime.status, .running)
  }

  // MARK: - 运行时变化重观察

  func testRuntimeChangeRepublishesWholeSnapshotWithoutCommand() {
    runtime.runtimeFacts = ProxyRuntimeFacts(status: .starting, isOn: true)
    runtime.emitChange()
    XCTAssertEqual(workflow.snapshot.runtime.status, .starting)

    runtime.runtimeFacts = ProxyRuntimeFacts(status: .running, isOn: true)
    runtime.emitChange()
    XCTAssertEqual(workflow.snapshot.runtime.status, .running)
    XCTAssertTrue(workflow.snapshot.runtime.isOn)
  }

  // MARK: - 窄目录目标事实缝

  func testActiveTargetFactsComeFromNarrowCatalogSeam() {
    runtime.activeTargetID = Self.serverID
    targetFacts.pathByTarget[Self.serverID] = "订阅分组 / 香港 01"
    runtime.emitChange()

    XCTAssertEqual(
      workflow.snapshot.activeTarget,
      ProxyActiveTargetFacts(id: Self.serverID, pathSummary: "订阅分组 / 香港 01"))
    XCTAssertEqual(targetFacts.queriedTargetIDs.last, Self.serverID)
  }

  func testNoActiveTargetYieldsNilTargetFacts() {
    XCTAssertNil(workflow.snapshot.activeTarget)
    XCTAssertEqual(targetFacts.queriedTargetIDs, [nil] as [NodeID?], "init 观察即查询一次")
  }

  func testTargetMissingFromTreeKeepsExistenceWithNilSummary() {
    runtime.activeTargetID = Self.serverID
    targetFacts.pathByTarget[Self.serverID] = nil
    runtime.emitChange()

    let target = workflow.snapshot.activeTarget
    XCTAssertEqual(target?.id, Self.serverID, "存在性来自活动目标身份")
    XCTAssertNil(target?.pathSummary, "目标不在当前目录树中时摘要为 nil")
  }

  // MARK: - 命令边界（story 37）

  func testCommandsTouchOnlyRuntimeAndTargetFactsAdapters() async {
    await workflow.setProxyEnabled(true)
    await workflow.setProxyMode(.global)
    await workflow.resyncOnLaunch()

    XCTAssertEqual(runtime.enabledCommands, [true])
    XCTAssertEqual(runtime.modeCommands, [.global])
    XCTAssertEqual(runtime.resyncCount, 1)
    // 目标缝只被 snapshot 组装读取；目录激活、订阅刷新、设置保存与诊断导出
    // 不在本 module 的依赖面上（类型层面不存在这些入口）。
    XCTAssertFalse(targetFacts.queriedTargetIDs.isEmpty, "每次观察经窄缝取目标事实")
  }
}
