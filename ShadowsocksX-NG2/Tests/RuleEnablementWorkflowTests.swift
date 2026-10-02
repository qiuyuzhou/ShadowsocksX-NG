import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class RuleEnablementWorkflowTests: XCTestCase {
  func testSuccessfulCommitDoesNotReadSourcesOrUserDocumentAgain() async throws {
    let reads = RulesReadCounts()
    let rule = CustomRule(action: .proxy, match: .domainExact("saved.example"))
    let workflow = RulesWorkflow(
      loadDocument: {
        reads.recordDocument()
        return CustomRuleDocument(rules: [rule])
      },
      commitDocument: { RuleDocumentCommit(outcome: .saved, document: $0) },
      loadBuiltin: { source in
        reads.recordSource()
        return rulesFixture(source)
      })
    await workflow.refresh()
    await workflow.setEnabled(false, identities: [rule.identity])
    XCTAssertEqual(reads.documentCount, 1)
    XCTAssertEqual(reads.sourceCount, 3)
    XCTAssertFalse(
      try XCTUnwrap(workflow.snapshot.rows.first { $0.identity == rule.identity }).isEnabled)
  }

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
          return RuleDocumentCommit(outcome: .saved, document: document)
        } catch {
          XCTFail("Fixture save failed: \(error)")
          return RuleDocumentCommit(
            outcome: .persistenceFailed, document: try? store.loadDocument())
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
    XCTAssertEqual(feedback.operation, .enablement(false))
    XCTAssertEqual(workflow.snapshot.operationStatus, .feedback(feedback))
    XCTAssertFalse(workflow.snapshot.rows.first { $0.identity == rule.identity }!.isEnabled)
  }

  func testFailedSaveKeepsSnapshotWithoutReload() async throws {
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
        return RuleDocumentCommit(outcome: .persistenceFailed, document: try? store.loadDocument())
      },
      loadBuiltin: { rulesFixture($0) })
    await workflow.refresh()
    let version = workflow.snapshot.version
    await workflow.setEnabled(false, identities: [rule.identity])
    XCTAssertEqual(workflow.snapshot.commitOutcome, .persistenceFailed)
    XCTAssertEqual(workflow.snapshot.version, version)
    XCTAssertTrue(workflow.snapshot.rows.first { $0.identity == rule.identity }!.isEnabled)
    XCTAssertEqual(commits, 1)
  }
}

private final class RulesReadCounts: @unchecked Sendable {
  private let lock = NSLock()
  private var documents = 0
  private var sources = 0
  func recordDocument() { lock.withLock { documents += 1 } }
  func recordSource() { lock.withLock { sources += 1 } }
  var documentCount: Int { lock.withLock { documents } }
  var sourceCount: Int { lock.withLock { sources } }
}
