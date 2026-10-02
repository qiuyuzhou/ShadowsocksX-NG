import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class RuleEnablementWorkflowTests: XCTestCase {
  func testInFlightBatchRejectsRepeatedCommandAndPublishesProgress() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CustomRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
    let rule = CustomRule(action: .proxy, match: .domainExact("example.net"))
    try store.save([rule])
    let started = expectation(description: "commit started")
    var continuation: CheckedContinuation<Void, Never>?
    var commits = 0
    let workflow = RulesWorkflow(
      loadDocument: { try store.loadDocument() },
      commitDocument: { document in
        commits += 1
        await withCheckedContinuation {
          continuation = $0
          started.fulfill()
        }
        do {
          try store.saveDocument(document)
          return .saved
        } catch {
          XCTFail("Fixture save failed: \(error)")
          return .persistenceFailed
        }
      },
      loadBuiltin: { rulesFixture($0) })
    await workflow.refresh()
    let pending = Task { await workflow.setEnabled(false, identities: [rule.identity]) }
    await fulfillment(of: [started], timeout: 3)
    XCTAssertTrue(workflow.snapshot.isCommitting)
    XCTAssertEqual(workflow.snapshot.operationStatus, .updating)
    XCTAssertNil(workflow.snapshot.commitFeedback)
    await workflow.setEnabled(false, identities: [rule.identity])
    await workflow.refresh()
    XCTAssertEqual(commits, 1)
    continuation?.resume()
    await pending.value
    XCTAssertFalse(workflow.snapshot.isCommitting)
    XCTAssertEqual(workflow.snapshot.commitOutcome, .saved)
    let feedback = try XCTUnwrap(workflow.snapshot.commitFeedback)
    XCTAssertEqual(feedback.changedCount, 1)
    XCTAssertFalse(feedback.enabled)
    XCTAssertEqual(workflow.snapshot.operationStatus, .feedback(feedback))
    XCTAssertFalse(workflow.snapshot.rows.first { $0.identity == rule.identity }!.isEnabled)
  }

  func testFailedSaveKeepsSnapshotAndExternalDocumentChangeRejectsStaleCommand() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = CustomRuleStore(fileURL: directory.appendingPathComponent("rules.json"))
    let rule = CustomRule(action: .direct, match: .domainExact("kept.example"))
    try store.save([rule])
    var commits = 0
    let workflow = RulesWorkflow(
      loadDocument: { try store.loadDocument() },
      commitDocument: { _ in
        commits += 1
        return .persistenceFailed
      },
      loadBuiltin: { rulesFixture($0) })
    await workflow.refresh()
    let version = workflow.snapshot.version
    await workflow.setEnabled(false, identities: [rule.identity])
    XCTAssertEqual(workflow.snapshot.commitOutcome, .persistenceFailed)
    XCTAssertEqual(workflow.snapshot.version, version)
    XCTAssertTrue(workflow.snapshot.rows.first { $0.identity == rule.identity }!.isEnabled)
    let selected = try XCTUnwrap(workflow.snapshot.rows.first { $0.identity == rule.identity }?.id)
    workflow.select([selected])
    try store.saveDocument(CustomRuleDocument(rules: [rule], disabledIdentities: [rule.identity]))
    await workflow.setEnabled(false, identities: [rule.identity])
    XCTAssertEqual(workflow.snapshot.commitOutcome, .versionConflict)
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(workflow.snapshot.version, version)
    XCTAssertEqual(workflow.snapshot.selection, [selected])
    XCTAssertTrue(workflow.snapshot.rows.first { $0.identity == rule.identity }!.isEnabled)
    await workflow.refresh()
    XCTAssertTrue(workflow.snapshot.selection.isEmpty)
    XCTAssertFalse(workflow.snapshot.rows.first { $0.identity == rule.identity }!.isEnabled)
  }
}
