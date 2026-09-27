import XCTest

@testable import ShadowsocksX_NG2

extension SettingsWorkflowInterfaceTests {
  // MARK: - 提交中与失败点名文案

  func testCommitFailureSurfacesNamedReasonAndKeepsDraft() async throws {
    committing.updateError = FakeCommitError.io
    let workflow = makeWorkflow()
    workflow.draft.proxyExceptions = "localhost"

    _ = await workflow.save()
    await waitUntil(workflow.lastFailure != nil)

    XCTAssertEqual(workflow.lastFailure, .unknown)
    XCTAssertEqual(workflow.lastFailure?.presentableMessage, AppPresentation.unknownError)
    XCTAssertFalse(workflow.isCommitting)
    XCTAssertEqual(workflow.draft.proxyExceptions, "localhost", "失败不吞掉草稿")
    XCTAssertEqual(
      committing.committedSettings.proxyExceptions,
      ProxySettings.defaultProxyExceptions,
      "失败不半提交")
    XCTAssertTrue(workflow.isDirty)
  }

  func testStorageAndCredentialFailuresNameTheReason() async throws {
    let workflow = makeWorkflow()
    workflow.draft.proxyExceptions = "localhost"

    committing.updateError = ProxySettingsStoreError.ioFailure(detail: "disk full")
    _ = await workflow.save()
    await waitUntil(!workflow.isCommitting)
    XCTAssertEqual(
      workflow.lastFailure,
      .store(.ioFailure(detail: "disk full")))
    XCTAssertTrue(workflow.lastFailure?.presentableMessage.contains("偏好文件") == true)

    let reference = CredentialReference(rawValue: "test-ref")
    committing.updateError = ProxySettingsStoreError.missingCredential(reference)
    _ = await workflow.save()
    await waitUntil(
      workflow.lastFailure
        == .store(.missingCredential(reference)))
    XCTAssertEqual(
      workflow.lastFailure,
      .store(.missingCredential(reference)))
  }

  func testCommittingStateBlocksRepeatedSave() async throws {
    committing.updateGate = AsyncGate()
    let workflow = makeWorkflow()
    workflow.draft.proxyExceptions = "localhost"

    let first = Task { await workflow.save() }
    await Task.yield()
    await waitUntil(workflow.isCommitting)
    XCTAssertTrue(workflow.isCommitting)
    XCTAssertFalse(workflow.canSave, "提交中保存门禁关闭")

    let second = await workflow.save()
    committing.updateGate?.release()
    _ = await first.value
    XCTAssertEqual(second, .rejected(.inProgress))
    XCTAssertEqual(committing.updateCalls.count, 1, "提交中不得重复触发")
  }

  private enum FakeCommitError: Error, CustomStringConvertible {
    // swiftlint:disable:next identifier_name
    case io

    var description: String { "fake-io-error" }
  }
}
