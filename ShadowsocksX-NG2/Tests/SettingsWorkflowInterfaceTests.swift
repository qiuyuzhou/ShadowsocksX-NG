import XCTest

@testable import ShadowsocksX_NG2

/// 设置工作流 UI-facing interface 测试（issue #44）：观察平坦草稿、按字段
/// 归位的问题、端口 field state、确认事实与操作区投影；写入缝与占用探测
/// 全部注入替身，不碰真实偏好文件、钥匙串与系统端口。
@MainActor
final class SettingsWorkflowInterfaceTests: XCTestCase {
  var committing: FakeSettingsCommitter!
  var probe: FakeOccupancyProbe!

  override func setUpWithError() throws {
    try super.setUpWithError()
    committing = FakeSettingsCommitter()
    probe = FakeOccupancyProbe()
  }

  func makeWorkflow() -> SettingsWorkflow {
    SettingsWorkflow(committing: committing, occupancyProbe: probe)
  }

  // MARK: - 校验问题按字段归位

  func testPortOutOfRangeIssueLandsOnThatPortField() {
    let workflow = makeWorkflow()
    workflow.draft.socksPort = 0

    XCTAssertEqual(
      workflow.fieldIssues,
      [
        .port(
          .socks,
          error: .portOutOfRange(endpoint: .socks, port: 0))
      ])
    XCTAssertEqual(
      workflow.issues(for: .port(.socks)),
      [.port(.socks, error: .portOutOfRange(endpoint: .socks, port: 0))])
    XCTAssertTrue(workflow.issues(for: .port(.http)).isEmpty)
  }

  func testDuplicatePortIssueLandsOnBothPortsInvolved() {
    let workflow = makeWorkflow()
    workflow.draft.httpPort = workflow.draft.socksPort

    let error = ProxySettingsValidationError.duplicatePort(
      endpoint: .socks, otherEndpoint: .http, port: 11086)
    XCTAssertEqual(
      workflow.fieldIssues,
      [.port(.socks, error: error), .port(.http, error: error)])
    XCTAssertEqual(workflow.issues(for: .port(.socks)), [.port(.socks, error: error)])
    XCTAssertEqual(workflow.issues(for: .port(.http)), [.port(.http, error: error)])
  }

  func testCommittedListenerModeIsReadSeparatelyFromTheFormDraft() {
    let workflow = makeWorkflow()
    committing.committedSettings.listen.listenerMode = .allIPv6Interfaces

    XCTAssertEqual(workflow.beginListenerModeEditing(), .allIPv6Interfaces)
    XCTAssertTrue(workflow.fieldIssues.isEmpty)
    XCTAssertFalse(workflow.isDirty)
  }

  // MARK: - 端口 field state

  func testPortFieldStateReportsFreeOccupiedAndUnknownFacts() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11087])
    let workflow = makeWorkflow()
    _ = await workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertEqual(workflow.portFieldState(for: .socks).occupancy, .free)
    XCTAssertEqual(workflow.portFieldState(for: .http).occupancy, .occupied(occupier: "other-app"))
    XCTAssertEqual(workflow.portFieldState(for: .socks).draftValue, 11086)

    probe = FakeOccupancyProbe(unknownPorts: [11086])
    let unknownWorkflow = makeWorkflow()
    _ = await unknownWorkflow.reloadFromCommitted()
    await waitUntil(unknownWorkflow.portFieldState(for: .socks).occupancy != nil)
    XCTAssertEqual(
      unknownWorkflow.portFieldState(for: .socks).occupancy, .unknown(detail: "无法判定"))
  }

  func testOccupancyProbeReceivesTheCompleteEffectiveListenIdentity() async throws {
    committing.committedSettings.listen.listenerMode = .allIPv4Interfaces
    _ = makeWorkflow()
    let expected = RuntimeListenFacts(
      listenerMode: .allIPv4Interfaces,
      socksPort: 11086,
      httpPort: 11087)

    await waitUntil(probe.requests.contains { $0.listen == expected })

    XCTAssertEqual(probe.requests.first(where: { $0.listen == expected })?.endpoint, .socks)
    XCTAssertEqual(probe.requests.first(where: { $0.listen == expected })?.bindAddress, "0.0.0.0")
  }

  func testOccupiedPortCarriesOccupierFact() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11086])
    let workflow = makeWorkflow()
    _ = await workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertEqual(workflow.portFieldState(for: .socks).occupancy, .occupied(occupier: "other-app"))
    XCTAssertTrue(workflow.portFieldState(for: .socks).canSuggestFreePort)
  }

  // MARK: - 运行中端口例外

  func testRuntimePortExceptionWhenProxyRunsAndPortUnchanged() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11086])
    committing.isProxyRunning = true
    let workflow = makeWorkflow()
    _ = await workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertTrue(workflow.portFieldState(for: .socks).isRuntimePortException)
    XCTAssertFalse(workflow.hasBlockingPortOccupancy)
    XCTAssertFalse(workflow.portFieldState(for: .socks).canSuggestFreePort)
  }

  func testNoRuntimePortExceptionWhenProxyStopped() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11086])
    committing.isProxyRunning = false
    let workflow = makeWorkflow()
    _ = await workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertFalse(workflow.portFieldState(for: .socks).isRuntimePortException)
    XCTAssertTrue(workflow.hasBlockingPortOccupancy)
  }

  func testNoRuntimePortExceptionWhenPortChanged() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [12086])
    committing.isProxyRunning = true
    let workflow = makeWorkflow()
    workflow.draft.socksPort = 12086
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertFalse(workflow.portFieldState(for: .socks).isRuntimePortException)
    XCTAssertTrue(workflow.hasBlockingPortOccupancy)
    XCTAssertFalse(workflow.canSave)
  }

  func testRuntimePortExceptionRequiresTheCompleteListenIdentity() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11086])
    committing.isProxyRunning = true
    let workflow = makeWorkflow()
    _ = await workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)
    XCTAssertTrue(workflow.portFieldState(for: .socks).isRuntimePortException)

    committing.runtimeListenFacts = RuntimeListenFacts(
      listenerMode: .allIPv4Interfaces,
      socksPort: 11086,
      httpPort: 11087)
    _ = await workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertFalse(
      workflow.portFieldState(for: .socks).isRuntimePortException,
      "同端口但 bind/public 地址不同不能作为当前 runtime 例外")
    XCTAssertTrue(workflow.hasBlockingPortOccupancy)
  }
}

extension SettingsWorkflowInterfaceTests {

  // MARK: - 建议空闲端口

  func testSuggestFreePortOnlyWritesThatPortFieldIntoDraft() async throws {
    let workflow = makeWorkflow()

    _ = await workflow.suggestFreePort(for: .socks)
    await waitUntil(workflow.draft.socksPort != 11086)

    XCTAssertEqual(workflow.draft.socksPort, 32768)
    XCTAssertEqual(workflow.portFieldState(for: .socks).draftValue, 32768)
    XCTAssertEqual(workflow.draft.httpPort, 11087)
    XCTAssertTrue(committing.updateCalls.isEmpty, "建议只改草稿，必须经用户保存")
  }

  // MARK: - 保存门禁

  func testValidationIssuesBlockSave() async throws {
    let workflow = makeWorkflow()
    workflow.draft.socksPort = 0

    XCTAssertFalse(workflow.canSave)

    _ = await workflow.save()
    await waitUntil(!workflow.isCommitting)
    XCTAssertTrue(committing.updateCalls.isEmpty)
  }

  func testBlockingOccupancyBlocksSave() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [12086])
    let workflow = makeWorkflow()
    workflow.draft.socksPort = 12086
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertTrue(workflow.hasBlockingPortOccupancy)
    XCTAssertFalse(workflow.canSave)

    _ = await workflow.save()
    XCTAssertTrue(committing.updateCalls.isEmpty)
  }

  func testSaveCommitsWhenGateClear() async throws {
    let workflow = makeWorkflow()
    workflow.draft.proxyExceptions = "localhost"

    XCTAssertTrue(workflow.canSave)
    let outcome = await workflow.save()

    XCTAssertEqual(outcome, .persisted)
    XCTAssertEqual(committing.updateCalls.first?.proxyExceptions, "localhost")
  }

  func testSaveReturnsAValidationRejectionWithoutStartingACommit() async throws {
    let workflow = makeWorkflow()
    workflow.draft.socksPort = 0

    let outcome = await workflow.save()

    XCTAssertEqual(
      outcome,
      .rejected(.validation([.port(.socks, error: .portOutOfRange(endpoint: .socks, port: 0))])))
    XCTAssertFalse(workflow.isCommitting)
    XCTAssertTrue(committing.updateCalls.isEmpty)
  }

  func testSettingsSaveDoesNotExposeProxyRuntimeStatus() async throws {
    let workflow = makeWorkflow()
    workflow.draft.proxyExceptions = "localhost"

    let outcome = await workflow.save()

    XCTAssertEqual(outcome, .persisted)
    XCTAssertNil(workflow.lastFailure)
    XCTAssertEqual(committing.committedSettings.proxyExceptions, "localhost")
  }

  func testRepeatedSaveReturnsAnInProgressRejection() async throws {
    committing.updateGate = AsyncGate()
    let workflow = makeWorkflow()
    workflow.draft.proxyExceptions = "localhost"

    let first = Task { await workflow.save() }
    await Task.yield()
    await waitUntil(workflow.isCommitting)
    let second = await workflow.save()
    committing.updateGate?.release()
    let firstOutcome = await first.value

    XCTAssertEqual(second, .rejected(.inProgress))
    XCTAssertEqual(firstOutcome, .persisted)
    XCTAssertEqual(committing.updateCalls.count, 1)
  }

  // MARK: - 脏态

  func testDirtyStateTracksDraftAgainstCommittedSnapshot() async throws {
    let workflow = makeWorkflow()
    XCTAssertFalse(workflow.isDirty)

    workflow.draft.proxyExceptions = "localhost"
    XCTAssertTrue(workflow.isDirty)

    _ = await workflow.reloadFromCommitted()
    XCTAssertFalse(workflow.isDirty)

    workflow.draft.proxyExceptions = "localhost"
    _ = await workflow.save()
    await waitUntil(!workflow.isCommitting)
    XCTAssertFalse(workflow.isDirty, "提交成功后草稿回到已提交快照")
    XCTAssertEqual(workflow.draft.proxyExceptions, "localhost")
  }

  func testListenerModeSavePreservesUnrelatedUnsavedFormChanges() async throws {
    let workflow = makeWorkflow()
    workflow.draft.proxyExceptions = "unsaved.example"

    let outcome = await workflow.saveListenerMode(.allIPv4AndIPv6Interfaces)

    XCTAssertEqual(outcome, .saved(unknownOccupancy: []))
    XCTAssertEqual(committing.committedSettings.listen.listenerMode, .allIPv4AndIPv6Interfaces)
    XCTAssertEqual(
      committing.committedSettings.proxyExceptions, ProxySettings.defaultProxyExceptions)
    XCTAssertEqual(workflow.draft.proxyExceptions, "unsaved.example")
    XCTAssertTrue(workflow.isDirty)
    XCTAssertFalse(committing.committedSettings.agentEnabled, "保存监听方式不启动已关闭的代理")
    XCTAssertEqual(committing.updateCalls.count, 1)
  }

  func testListenerModeKnownExternalPortConflictBlocksOnlyThatSave() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11087])
    let workflow = makeWorkflow()

    let outcome = await workflow.saveListenerMode(.allIPv4Interfaces)

    XCTAssertEqual(outcome, .rejected(.occupied([.http])))
    XCTAssertTrue(committing.updateCalls.isEmpty)
    XCTAssertEqual(committing.committedSettings.listen.listenerMode, .localhost)
  }

  func testListenerModeSavesWhenOccupancyIsUnknownAndReturnsWarningFacts() async throws {
    probe = FakeOccupancyProbe(unknownPorts: [11086])
    let workflow = makeWorkflow()

    let outcome = await workflow.saveListenerMode(.allIPv6Interfaces)

    XCTAssertEqual(outcome, .saved(unknownOccupancy: [.socks]))
    XCTAssertEqual(committing.committedSettings.listen.listenerMode, .allIPv6Interfaces)
  }

  func testModeIsNotPartOfTheDraft() async throws {
    var committed = committing.committedSettings
    committed.preferredMode = .global
    committing.committedSettings = committed

    let workflow = makeWorkflow()
    workflow.draft.proxyExceptions = "localhost"
    _ = await workflow.save()
    await waitUntil(!workflow.isCommitting)

    XCTAssertEqual(committing.updateCalls.first?.preferredMode, .global, "草稿不编辑当前模式")
  }

  // MARK: - 占用探测代际

  func testStaleOccupancyResultDoesNotOverrideNewerGeneration() async throws {
    let gated = GatedOccupancyProbe(
      gatedAnswer: .occupied(
        PortOccupancyFacts(
          occupier: "stale", occupiedFamilies: [.ipv4], verifiedFamilies: [.ipv4])),
      passThroughAnswer: .free)
    let workflow = SettingsWorkflow(committing: committing, occupancyProbe: gated)

    await waitUntil(gated.entered > 0)
    gated.passThrough(.free)
    workflow.draft.socksPort = 30086
    await waitUntil(workflow.portFieldState(for: .socks).occupancy == .free)

    gated.releaseGatedCalls()
    try? await Task.sleep(nanoseconds: 50_000_000)
    XCTAssertEqual(
      workflow.portFieldState(for: .socks).occupancy, .free,
      "过期的占用结果不得覆盖较新一轮")
  }

  func testReloadWithUnlistenChangesStillRefreshesOccupancy() async throws {
    probe = FakeOccupancyProbe()
    let workflow = makeWorkflow()
    _ = await workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy == .free)

    let laterOccupancy = PortOccupancyFacts(
      occupier: "later", occupiedFamilies: [.ipv4], verifiedFamilies: [.ipv4])
    probe.setAnswer(.occupied(laterOccupancy))
    _ = await workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != .free)

    XCTAssertEqual(
      workflow.portFieldState(for: .socks).occupancy, .occupied(occupier: "later"),
      "监听设置未变的刷新仍产生新占用事实")
  }
}
