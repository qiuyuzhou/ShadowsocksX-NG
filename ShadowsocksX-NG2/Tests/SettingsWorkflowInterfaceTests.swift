import XCTest

@testable import ShadowsocksX_NG2

/// 设置工作流 UI-facing interface 测试（issue #44）：观察平坦草稿、按字段
/// 归位的问题、端口 field state、确认事实与操作区投影；写入缝与占用探测
/// 全部注入替身，不碰真实偏好文件、钥匙串与系统端口。
@MainActor
final class SettingsWorkflowInterfaceTests: XCTestCase {
  private var committing: FakeSettingsCommitter!
  private var probe: FakeOccupancyProbe!

  override func setUpWithError() throws {
    try super.setUpWithError()
    committing = FakeSettingsCommitter()
    probe = FakeOccupancyProbe()
  }

  private func makeWorkflow() -> SettingsWorkflow {
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
    XCTAssertTrue(workflow.issues(for: .port(.pac)).isEmpty)
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
    XCTAssertTrue(workflow.issues(for: .port(.pac)).isEmpty)
  }

  func testTimeoutIssueLandsOnTimeoutField() {
    let workflow = makeWorkflow()
    workflow.draft.timeoutSeconds = 0

    XCTAssertEqual(
      workflow.fieldIssues,
      [.timeoutSeconds(error: .invalidTimeout(0))])
    XCTAssertTrue(workflow.issues(for: .port(.socks)).isEmpty)
  }

  func testHostAddressIssueLandsOnAdvertisedAddressField() {
    let workflow = makeWorkflow()
    workflow.draft.isHostScope = true
    workflow.draft.advertisedAddress = "127.0.0.1"

    XCTAssertEqual(workflow.fieldIssues.map(\.field), [.advertisedAddress])
    XCTAssertTrue(
      AppPresentation.message(for: workflow.issues(for: .advertisedAddress)[0]).contains("主机地址"))
  }

  func testGFWListURLIssueLandsOnItsField() {
    let workflow = makeWorkflow()
    workflow.draft.gfwListURL = "not a url"

    XCTAssertEqual(workflow.fieldIssues.map(\.field), [.gfwListURL])
    XCTAssertTrue(
      AppPresentation.message(for: workflow.issues(for: .gfwListURL)[0])
        .contains("GFW List URL"))
  }

  // MARK: - 端口 field state

  func testPortFieldStateReportsFreeOccupiedAndUnknownFacts() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11087], unknownPorts: [11089])
    let workflow = makeWorkflow()
    workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .pac).occupancy != nil)

    XCTAssertEqual(workflow.portFieldState(for: .socks).occupancy, .free)
    XCTAssertEqual(workflow.portFieldState(for: .http).occupancy, .occupied(occupier: "other-app"))
    XCTAssertEqual(workflow.portFieldState(for: .pac).occupancy, .unknown(detail: "无法判定"))
    XCTAssertEqual(workflow.portFieldState(for: .socks).draftValue, 11086)
  }

  func testOccupiedPortCarriesOccupierFact() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11086])
    let workflow = makeWorkflow()
    workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertEqual(workflow.portFieldState(for: .socks).occupancy, .occupied(occupier: "other-app"))
    XCTAssertTrue(workflow.portFieldState(for: .socks).canSuggestFreePort)
  }

  func testDisabledHTTPEndpointDoesNotParticipateInSaveGating() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11087])
    let workflow = makeWorkflow()
    workflow.draft.httpProxyEnabled = false
    await waitUntil(workflow.portFieldState(for: .http).occupancy != nil)

    XCTAssertEqual(workflow.portFieldState(for: .http).occupancy, .occupied(occupier: "other-app"))
    XCTAssertFalse(workflow.hasBlockingPortOccupancy)
    XCTAssertTrue(workflow.canSave)
  }

  // MARK: - 运行中端口例外

  func testRuntimePortExceptionWhenProxyRunsAndPortUnchanged() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11086])
    committing.isProxyRunning = true
    let workflow = makeWorkflow()
    workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertTrue(workflow.portFieldState(for: .socks).isRuntimePortException)
    XCTAssertFalse(workflow.hasBlockingPortOccupancy)
    XCTAssertFalse(workflow.portFieldState(for: .socks).canSuggestFreePort)
  }

  func testNoRuntimePortExceptionWhenProxyStopped() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11086])
    committing.isProxyRunning = false
    let workflow = makeWorkflow()
    workflow.reloadFromCommitted()
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

  func testRuntimeExceptionRequiresCommittedHTTPInboundForHTTPPort() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [11087])
    committing.isProxyRunning = true
    var committed = committing.committedSettings
    committed.listen.httpProxyEnabled = false
    committing.committedSettings = committed

    let workflow = makeWorkflow()
    workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .http).occupancy != nil)

    XCTAssertFalse(workflow.portFieldState(for: .http).isRuntimePortException)
  }

  // MARK: - 建议空闲端口

  func testSuggestFreePortOnlyWritesThatPortFieldIntoDraft() async throws {
    let workflow = makeWorkflow()

    workflow.suggestFreePort(for: .socks)
    await waitUntil(workflow.draft.socksPort != 11086)

    XCTAssertEqual(workflow.draft.socksPort, 32768)
    XCTAssertEqual(workflow.portFieldState(for: .socks).draftValue, 32768)
    XCTAssertEqual(workflow.draft.httpPort, 11087)
    XCTAssertEqual(workflow.draft.pacPort, 11089)
    XCTAssertTrue(committing.updateCalls.isEmpty, "建议只改草稿，必须经用户保存")
  }

  // MARK: - 保存门禁

  func testValidationIssuesBlockSave() async throws {
    let workflow = makeWorkflow()
    workflow.draft.timeoutSeconds = 0

    XCTAssertFalse(workflow.canSave)

    workflow.save()
    await waitUntil(!workflow.isCommitting && workflow.pendingConfirmation == nil)
    XCTAssertTrue(committing.updateCalls.isEmpty)
  }

  func testBlockingOccupancyBlocksSave() async throws {
    probe = FakeOccupancyProbe(occupiedPorts: [12086])
    let workflow = makeWorkflow()
    workflow.draft.socksPort = 12086
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != nil)

    XCTAssertTrue(workflow.hasBlockingPortOccupancy)
    XCTAssertFalse(workflow.canSave)

    workflow.save()
    XCTAssertTrue(committing.updateCalls.isEmpty)
  }

  func testSaveCommitsWhenGateClear() async throws {
    let workflow = makeWorkflow()
    workflow.draft.timeoutSeconds = 120

    XCTAssertTrue(workflow.canSave)
    workflow.save()
    await waitUntil(!committing.updateCalls.isEmpty)

    XCTAssertEqual(committing.updateCalls.first?.timeoutSeconds, 120)
  }

  // MARK: - 脏态

  func testDirtyStateTracksDraftAgainstCommittedSnapshot() async throws {
    let workflow = makeWorkflow()
    XCTAssertFalse(workflow.isDirty)

    workflow.draft.timeoutSeconds = 120
    XCTAssertTrue(workflow.isDirty)

    workflow.reloadFromCommitted()
    XCTAssertFalse(workflow.isDirty)

    workflow.draft.timeoutSeconds = 120
    workflow.save()
    await waitUntil(!workflow.isCommitting)
    XCTAssertFalse(workflow.isDirty, "提交成功后草稿回到已提交快照")
    XCTAssertEqual(workflow.draft.timeoutSeconds, 120)
  }

  func testHiddenHostAddressLeftoverDoesNotReportDirty() {
    let workflow = makeWorkflow()
    workflow.draft.isHostScope = true
    workflow.draft.advertisedAddress = "192.168.1.10"
    XCTAssertTrue(workflow.isDirty)

    workflow.draft.isHostScope = false
    XCTAssertFalse(
      workflow.isDirty,
      "仅本机模式下残留的地址文本不改变已提交快照，不算未保存修改")
  }

  func testModeIsNotPartOfTheDraft() async throws {
    var committed = committing.committedSettings
    committed.preferredMode = .global
    committing.committedSettings = committed

    let workflow = makeWorkflow()
    workflow.draft.timeoutSeconds = 120
    workflow.save()
    await waitUntil(!workflow.isCommitting)

    XCTAssertEqual(committing.updateCalls.first?.preferredMode, .global, "草稿不编辑当前模式")
  }

  // MARK: - PAC 失效确认

  func testPACPortChangeArmsConfirmationBeforeCommit() async throws {
    let workflow = makeWorkflow()
    workflow.draft.pacPort = 13089

    workflow.save()

    guard case .pacInvalidation(_, let nextPort)? = workflow.pendingConfirmation else {
      return XCTFail("应挂起 PAC 失效确认，实际 \(String(describing: workflow.pendingConfirmation))")
    }
    XCTAssertEqual(nextPort, 13089)
    XCTAssertTrue(
      AppPresentation.message(for: .pacInvalidation(previousPort: 11089, nextPort: nextPort))
        .contains("13089"))
    XCTAssertTrue(committing.updateCalls.isEmpty, "未确认失效提示不得提交")

    workflow.confirmPACNotice()
    await waitUntil(!workflow.isCommitting)
    XCTAssertNil(workflow.pendingConfirmation)
    XCTAssertEqual(committing.updateCalls.first?.listen.pacPort, 13089)
  }

  func testCancelingPACNoticeKeepsDraftAndDoesNotCommit() async throws {
    let workflow = makeWorkflow()
    workflow.draft.pacPort = 13089

    workflow.save()
    workflow.cancelPACNotice()

    XCTAssertNil(workflow.pendingConfirmation)
    XCTAssertTrue(committing.updateCalls.isEmpty)
    XCTAssertEqual(workflow.draft.pacPort, 13089, "取消后草稿保留待调整值")
    XCTAssertEqual(committing.committedSettings.listen.pacPort, 11089)
    XCTAssertTrue(workflow.isDirty)
  }

  // MARK: - 重置确认

  func testResetArmsConfirmationWithScopeSummaryFromSeam() {
    let workflow = makeWorkflow()

    workflow.reset()

    guard case .resetPreferences? = workflow.pendingConfirmation else {
      return XCTFail("应挂起重置确认，实际 \(String(describing: workflow.pendingConfirmation))")
    }
    let summary = AppPresentation.message(for: .resetPreferences)
    XCTAssertTrue(summary.contains("端口"))
    XCTAssertTrue(summary.contains("监听范围"))
    XCTAssertTrue(summary.contains("PAC"))
    XCTAssertTrue(summary.contains("全部偏好"), "摘要范围与重置事务一致")
    XCTAssertTrue(summary.contains("代理"), "摘要点名运行中代理会停止")
    XCTAssertTrue(committing.updateCalls.isEmpty)
    XCTAssertEqual(committing.resetCallCount, 0)
  }

  func testConfirmingResetUsesTheResetCommitEntry() async throws {
    let workflow = makeWorkflow()
    workflow.draft.timeoutSeconds = 120

    workflow.reset()
    workflow.confirmReset()
    await waitUntil(!workflow.isCommitting)
    XCTAssertEqual(committing.resetCallCount, 1)

    XCTAssertNil(workflow.pendingConfirmation)
    XCTAssertTrue(committing.updateCalls.isEmpty, "重置走重置提交入口，不走设置提交")
    XCTAssertEqual(workflow.draft, SettingsDraftAdapter.draft(from: ProxySettings()))
  }

  func testCancelingResetDoesNotCommit() {
    let workflow = makeWorkflow()

    workflow.reset()
    workflow.cancelReset()

    XCTAssertNil(workflow.pendingConfirmation)
    XCTAssertEqual(committing.resetCallCount, 0)
    XCTAssertTrue(committing.updateCalls.isEmpty)
  }

  // MARK: - 提交中与失败点名文案

  func testCommitFailureSurfacesNamedReasonAndKeepsDraft() async throws {
    committing.updateError = FakeCommitError.io
    let workflow = makeWorkflow()
    workflow.draft.timeoutSeconds = 120

    workflow.save()
    await waitUntil(workflow.lastFailure != nil)

    XCTAssertEqual(workflow.lastFailure, .unknown)
    XCTAssertEqual(workflow.lastFailure?.presentableMessage, AppPresentation.unknownError)
    XCTAssertFalse(workflow.isCommitting)
    XCTAssertEqual(workflow.draft.timeoutSeconds, 120, "失败不吞掉草稿")
    XCTAssertEqual(committing.committedSettings.timeoutSeconds, 60, "失败不半提交")
    XCTAssertTrue(workflow.isDirty)
  }

  func testStorageAndCredentialFailuresNameTheReason() async throws {
    let workflow = makeWorkflow()
    workflow.draft.timeoutSeconds = 120

    committing.updateError = ProxySettingsStoreError.ioFailure(detail: "disk full")
    workflow.save()
    await waitUntil(!workflow.isCommitting)
    XCTAssertEqual(
      workflow.lastFailure,
      .store(.ioFailure(detail: "disk full")))
    XCTAssertTrue(workflow.lastFailure?.presentableMessage.contains("偏好文件") == true)

    committing.updateError = ProxySettingsStoreError.missingCredential(
      ProxySettingsFileStore.gfwListReference)
    workflow.save()
    await waitUntil(
      workflow.lastFailure
        == .store(
          .missingCredential(ProxySettingsFileStore.gfwListReference)))
    XCTAssertEqual(
      workflow.lastFailure,
      .store(.missingCredential(ProxySettingsFileStore.gfwListReference)))
  }

  func testCommittingStateBlocksRepeatedSave() async throws {
    let workflow = makeWorkflow()
    workflow.draft.timeoutSeconds = 120

    workflow.save()
    XCTAssertTrue(workflow.isCommitting)
    XCTAssertFalse(workflow.canSave, "提交中保存门禁关闭")

    workflow.save()
    await waitUntil(!workflow.isCommitting)
    XCTAssertEqual(committing.updateCalls.count, 1, "提交中不得重复触发")
  }

  func testResetFailureSurfacesNamedReason() async throws {
    committing.resetError = FakeCommitError.io
    let workflow = makeWorkflow()

    workflow.reset()
    workflow.confirmReset()
    await waitUntil(workflow.lastFailure != nil)

    XCTAssertEqual(workflow.lastFailure, .unknown)
  }

  // MARK: - 占用探测代际

  func testStaleOccupancyResultDoesNotOverrideNewerGeneration() async throws {
    let gated = GatedOccupancyProbe(
      gatedAnswer: .occupied(occupier: "stale"), passThroughAnswer: .free)
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
    workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy == .free)

    probe.setAnswer(.occupied(occupier: "later"))
    workflow.reloadFromCommitted()
    await waitUntil(workflow.portFieldState(for: .socks).occupancy != .free)

    XCTAssertEqual(
      workflow.portFieldState(for: .socks).occupancy, .occupied(occupier: "later"),
      "监听设置未变的刷新仍产生新占用事实")
  }

  private enum FakeCommitError: Error, CustomStringConvertible {
    case io

    var description: String { "fake-io-error" }
  }
}
