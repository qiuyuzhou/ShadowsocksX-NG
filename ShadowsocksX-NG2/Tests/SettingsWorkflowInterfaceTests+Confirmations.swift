import XCTest

@testable import ShadowsocksX_NG2

extension SettingsWorkflowInterfaceTests {
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
