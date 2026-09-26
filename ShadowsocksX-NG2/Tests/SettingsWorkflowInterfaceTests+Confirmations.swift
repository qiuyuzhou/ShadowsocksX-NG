import XCTest

@testable import ShadowsocksX_NG2

extension SettingsWorkflowInterfaceTests {
  // MARK: - PAC 失效确认

  func testPACPortChangeArmsConfirmationBeforeCommit() async throws {
    let workflow = makeWorkflow()
    workflow.draft.pacPort = 13089

    _ = await workflow.save()

    guard case .pacInvalidation(_, let nextPort)? = workflow.pendingConfirmation else {
      return XCTFail("应挂起 PAC 失效确认，实际 \(String(describing: workflow.pendingConfirmation))")
    }
    XCTAssertEqual(nextPort, 13089)
    XCTAssertTrue(
      AppPresentation.message(for: .pacInvalidation(previousPort: 11089, nextPort: nextPort))
        .contains("13089"))
    XCTAssertTrue(committing.updateCalls.isEmpty, "未确认失效提示不得提交")

    _ = await workflow.confirmPACNotice()
    await waitUntil(!workflow.isCommitting)
    XCTAssertNil(workflow.pendingConfirmation)
    XCTAssertEqual(committing.updateCalls.first?.listen.pacPort, 13089)
  }

  func testCancelingPACNoticeKeepsDraftAndDoesNotCommit() async throws {
    let workflow = makeWorkflow()
    workflow.draft.pacPort = 13089

    _ = await workflow.save()
    _ = await workflow.cancelPACNotice()

    XCTAssertNil(workflow.pendingConfirmation)
    XCTAssertTrue(committing.updateCalls.isEmpty)
    XCTAssertEqual(workflow.draft.pacPort, 13089, "取消后草稿保留待调整值")
    XCTAssertEqual(committing.committedSettings.listen.pacPort, 11089)
    XCTAssertTrue(workflow.isDirty)
  }

  // MARK: - 重置确认

  func testResetArmsConfirmationWithScopeSummaryFromSeam() async throws {
    let workflow = makeWorkflow()

    _ = await workflow.reset()

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

    _ = await workflow.reset()
    _ = await workflow.confirmReset()
    await waitUntil(!workflow.isCommitting)
    XCTAssertEqual(committing.resetCallCount, 1)

    XCTAssertNil(workflow.pendingConfirmation)
    XCTAssertTrue(committing.updateCalls.isEmpty, "重置走重置提交入口，不走设置提交")
    XCTAssertEqual(workflow.draft, SettingsDraftAdapter.draft(from: ProxySettings()))
  }

  func testResetReturnsPersistedDefaultsAndIndependentRuntimeFailure() async throws {
    let runtimeFailure = RuntimeFailureFacts.systemProxy(.ownershipConflict)
    committing.resetOutcome = .failed(runtimeFailure)
    let workflow = makeWorkflow()

    _ = await workflow.reset()
    let outcome = await workflow.confirmReset()

    XCTAssertEqual(outcome, .persisted(runtime: .failed(runtimeFailure)))
    XCTAssertEqual(workflow.lastFailure, .runtime(runtimeFailure))
    XCTAssertEqual(workflow.draft, SettingsDraftAdapter.draft(from: ProxySettings()))
  }

  func testCancelingResetDoesNotCommit() async throws {
    let workflow = makeWorkflow()

    _ = await workflow.reset()
    _ = await workflow.cancelReset()

    XCTAssertNil(workflow.pendingConfirmation)
    XCTAssertEqual(committing.resetCallCount, 0)
    XCTAssertTrue(committing.updateCalls.isEmpty)
  }
}
