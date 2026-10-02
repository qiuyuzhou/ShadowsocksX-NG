import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class CustomRuleDeletionWorkflowTests: XCTestCase {
  func testMixedSelectionDeletesOnlyCustomUUIDsAndPreservesDisablementAndBuiltinMembership()
    async throws
  {
    let custom = CustomRule(action: .proxy, match: .domainSuffix("merged.example"))
    let other = CustomRule(action: .direct, match: .domainExact("other.example"))
    let orphan = RuleIdentity(action: .proxy, match: .domainExact("orphan.example"))
    let source = RuleSourceIdentity(kind: .gfwlist, upstreamVersion: "fixture", label: "GFWList")
    let builtin = ProxyRule(action: custom.action, match: custom.match, source: source)
    var saved = CustomRuleDocument(
      rules: [custom, other], disabledIdentities: [custom.identity, orphan])
    var commits = 0
    let workflow = RulesWorkflow(
      loadDocument: { saved },
      commitDocument: {
        commits += 1
        saved = $0
        return RuleDocumentCommit(outcome: .saved, document: saved)
      },
      loadBuiltin: { rulesFixture($0, rules: $0 == .gfwlist ? [builtin] : []) })
    await workflow.refresh()
    workflow.select(Set(workflow.snapshot.rows.map(\.id)))
    XCTAssertEqual(workflow.deletableSelection, [custom.id, other.id])
    let confirmation = try XCTUnwrap(workflow.prepareCustomRuleDeletion())
    XCTAssertEqual(confirmation.customIDs, [custom.id, other.id])
    XCTAssertEqual(commits, 0, "Preparing and discarding a confirmation has no side effects")
    let oldVersion = workflow.snapshot.version
    let result = await workflow.deleteCustomRules(confirmation)
    XCTAssertEqual(result, .committed(.saved))
    XCTAssertEqual(commits, 1)
    XCTAssertTrue(saved.rules.isEmpty)
    XCTAssertEqual(saved.disabledIdentities, [custom.identity, orphan])
    let merged = try XCTUnwrap(workflow.snapshot.rows.first { $0.identity == custom.identity })
    XCTAssertEqual(merged.sources, [.gfwlist])
    XCTAssertTrue(merged.customIDs.isEmpty)
    XCTAssertFalse(merged.isEnabled)
    XCTAssertNotEqual(workflow.snapshot.version, oldVersion)
    XCTAssertFalse(workflow.snapshot.rows.contains { $0.identity == other.identity })
    XCTAssertTrue(workflow.snapshot.selection.isSubset(of: Set(workflow.snapshot.rows.map(\.id))))
    XCTAssertEqual(workflow.snapshot.commitFeedback?.changedCount, 2)
  }
}

extension CustomRuleDeletionWorkflowTests {
  func testFilteredSelectionCannotEnterConfirmationAndStaleConfirmationCannotExpand() async throws {
    let first = CustomRule(action: .proxy, match: .domainExact("first.example"))
    let hidden = CustomRule(action: .direct, match: .domainExact("hidden.example"))
    var commits = 0
    var saved = CustomRuleDocument(rules: [first, hidden])
    let workflow = RulesWorkflow(
      loadDocument: { saved },
      commitDocument: {
        commits += 1
        saved = $0
        return RuleDocumentCommit(outcome: .saved, document: saved)
      }, loadBuiltin: { rulesFixture($0) })
    await workflow.refresh()
    workflow.select(Set(workflow.snapshot.rows.map(\.id)))
    var query = workflow.snapshot.query
    query.search = "first"
    workflow.query(query)
    let confirmation = try XCTUnwrap(workflow.prepareCustomRuleDeletion())
    XCTAssertEqual(confirmation.customIDs, [first.id])
    query.search = ""
    workflow.query(query)
    workflow.select(Set(workflow.snapshot.rows.map(\.id)))
    let deleted = await workflow.deleteCustomRules(confirmation)
    XCTAssertEqual(deleted, .committed(.saved))
    XCTAssertEqual(saved.rules.map(\.id), [hidden.id], "New selection cannot expand captured UUIDs")
    let stale = await workflow.deleteCustomRules(confirmation)
    XCTAssertEqual(stale, .unavailable(.staleConfirmation))
    XCTAssertEqual(commits, 1)
    workflow.select([])
    XCTAssertNil(workflow.prepareCustomRuleDeletion())
  }

  func testVersionChangeRejectsDeletionEvenWhenTheCustomUUIDStillExists() async throws {
    let rule = CustomRule(action: .proxy, match: .domainExact("kept.example"))
    var commits = 0
    let workflow = RulesWorkflow(
      loadDocument: { CustomRuleDocument(rules: [rule]) },
      commitDocument: {
        commits += 1
        return RuleDocumentCommit(outcome: .saved, document: $0)
      }, loadBuiltin: { rulesFixture($0) })
    await workflow.refresh()
    workflow.select(Set(workflow.snapshot.rows.map(\.id)))
    let confirmation = try XCTUnwrap(workflow.prepareCustomRuleDeletion())
    await workflow.setEnabled(false, identities: [rule.identity])
    let result = await workflow.deleteCustomRules(confirmation)
    XCTAssertEqual(result, .unavailable(.staleConfirmation))
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(workflow.deletableSelection, [rule.id])
  }

  func testPendingDeletionBlocksRepeatsAndPersistenceFailureKeepsConfirmationRetryable()
    async throws
  {
    let rule = CustomRule(action: .proxy, match: .domainExact("kept.example"))
    let original = CustomRuleDocument(rules: [rule])
    let started = expectation(description: "delete awaiting commit")
    var continuation: CheckedContinuation<Void, Never>?
    var commits = 0
    let workflow = RulesWorkflow(
      loadDocument: { original },
      commitDocument: { _ in
        commits += 1
        await withCheckedContinuation {
          continuation = $0
          started.fulfill()
        }
        return RuleDocumentCommit(outcome: .persistenceFailed, document: original)
      }, loadBuiltin: { rulesFixture($0) })
    await workflow.refresh()
    workflow.select(Set(workflow.snapshot.rows.map(\.id)))
    let confirmation = try XCTUnwrap(workflow.prepareCustomRuleDeletion())
    let pending = Task { await workflow.deleteCustomRules(confirmation) }
    await fulfillment(of: [started], timeout: 3)
    XCTAssertNil(workflow.prepareCustomRuleDeletion())
    let repeated = await workflow.deleteCustomRules(confirmation)
    XCTAssertEqual(repeated, .unavailable(.busy))
    continuation?.resume()
    let result = await pending.value
    XCTAssertEqual(result, .committed(.persistenceFailed))
    XCTAssertEqual(commits, 1)
    XCTAssertEqual(workflow.snapshot.version, confirmation.version)
    XCTAssertEqual(workflow.prepareCustomRuleDeletion(), confirmation)
  }

  func testIncompleteCollectionRejectsDeletionFromPreviouslyLoadedFacts() async throws {
    let rule = CustomRule(action: .proxy, match: .domainExact("kept.example"))
    var failed = false
    var commits = 0
    let workflow = RulesWorkflow(
      loadDocument: {
        if failed { throw CustomRuleStoreError.corrupt(detail: "fixture") }
        return CustomRuleDocument(rules: [rule])
      },
      commitDocument: {
        commits += 1
        return RuleDocumentCommit(outcome: .saved, document: $0)
      }, loadBuiltin: { rulesFixture($0) })
    await workflow.refresh()
    workflow.select(Set(workflow.snapshot.rows.map(\.id)))
    let confirmation = try XCTUnwrap(workflow.prepareCustomRuleDeletion())
    failed = true
    await workflow.refresh()
    XCTAssertNil(workflow.prepareCustomRuleDeletion())
    let result = await workflow.deleteCustomRules(confirmation)
    XCTAssertEqual(result, .unavailable(.incompleteCollection))
    XCTAssertEqual(commits, 0)
  }
}
