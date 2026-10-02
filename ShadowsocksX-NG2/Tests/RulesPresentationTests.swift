import XCTest

@testable import ShadowsocksX_NG2

@MainActor
final class RulesPresentationTests: XCTestCase {
  func testReportIsAnExplicitSnapshotUnaffectedByQueryOrRefresh() async throws {
    let loader = ReportFixtureLoader()
    let workflow = RulesWorkflow(loadCustom: { [] }, loadBuiltin: { loader.load($0) })
    await workflow.refresh()
    XCTAssertTrue(workflow.openSourceReport(.gfwlist))
    let opened = try XCTUnwrap(workflow.reportSource)
    workflow.query(RulesQuery(source: .chinaIPv4))
    loader.advance()
    await workflow.refresh()
    XCTAssertEqual(workflow.reportSource, opened)
    XCTAssertTrue(workflow.openSourceReport(.gfwlist))
    XCTAssertEqual(workflow.reportSource, opened)
    XCTAssertTrue(workflow.openSourceReport(.chinaIPv4))
    XCTAssertEqual(workflow.reportSource?.id, .chinaIPv4)
    XCTAssertFalse(workflow.openSourceReport(.custom))
    XCTAssertEqual(workflow.reportSource?.id, .chinaIPv4)
  }
  func testRelationshipExplanationRequiresExactlyOneRelatedSelection() async throws {
    let broad = CustomRule(action: .proxy, match: try RuleMatch(domainSuffix: "example.com"))
    let narrow = CustomRule(action: .direct, match: try RuleMatch(domainExact: "a.example.com"))
    let independent = CustomRule(action: .direct, match: try RuleMatch(domainExact: "other.net"))
    let workflow = RulesWorkflow(
      loadCustom: { [broad, narrow, independent] }, loadBuiltin: { rulesFixture($0) })
    await workflow.refresh()
    XCTAssertNil(workflow.selectedRelationshipRow)
    workflow.select([.rule(narrow.identity)])
    let row = try XCTUnwrap(workflow.selectedRelationshipRow)
    XCTAssertEqual(row.identity, narrow.identity)
    XCTAssertEqual(row.relationships.first?.kind, .shadowing)
    XCTAssertEqual(row.relationships.first?.covering, [broad.identity])
    workflow.select([.rule(narrow.identity), .rule(independent.identity)])
    XCTAssertNil(workflow.selectedRelationshipRow)
    workflow.select([.rule(independent.identity)])
    XCTAssertNil(workflow.selectedRelationshipRow)
  }

  func testSameActionAndFixedCoverageRemainExplainable() async throws {
    let broad = CustomRule(action: .direct, match: try RuleMatch(domainSuffix: "example.net"))
    let narrow = CustomRule(action: .direct, match: try RuleMatch(domainExact: "a.example.net"))
    let local = CustomRule(action: .direct, match: try RuleMatch(domainExact: "device.local"))
    let workflow = RulesWorkflow(
      loadCustom: { [broad, narrow, local] }, loadBuiltin: { rulesFixture($0) })
    await workflow.refresh()
    workflow.select([.rule(narrow.identity)])
    let absorbed = try XCTUnwrap(workflow.selectedRelationshipRow)
    XCTAssertEqual(absorbed.relationships.first?.kind, .absorption)
    XCTAssertEqual(absorbed.relationships.first?.covering, [broad.identity])
    workflow.select([.rule(local.identity)])
    let fixed = try XCTUnwrap(workflow.selectedRelationshipRow?.fixedCoverage)
    XCTAssertEqual(fixed.matches, [.domainSuffix("local")])
    workflow.select([.noDotHostname])
    XCTAssertNil(workflow.selectedRelationshipRow)
  }

}

private final class ReportFixtureLoader: @unchecked Sendable {
  private let lock = NSLock()
  private var version = 1

  func advance() { lock.withLock { version += 1 } }

  func load(_ source: RulesSource) -> RuleSnapshot {
    let version = lock.withLock { version }
    let fixture = rulesFixture(source)
    let metadata = fixture.metadata
    return RuleSnapshot(
      metadata: RuleSnapshotMetadata(
        source: RuleSourceIdentity(
          kind: metadata.source.kind, upstreamVersion: "v\(version)", label: metadata.source.label),
        upstreamReference: metadata.upstreamReference, inputDigest: "digest-\(version)",
        fetchedAt: metadata.fetchedAt, license: metadata.license, attribution: metadata.attribution),
      rules: fixture.rules, lossReport: RuleConversionLossReport(absorbedCount: version))
  }
}
