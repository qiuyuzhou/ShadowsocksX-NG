import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// 订阅刷新失败的 durable seam：只观察可演进的安全事实，不观察文案或
/// transient Error 的实现细节。
final class SubscriptionRefreshFailureTests: XCTestCase {
  func testAllDurableFailureFactsRoundTrip() throws {
    let failures: [SubscriptionRefreshFailure] = [
      .invalidURL,
      .unsupportedScheme,
      .insecureRedirect,
      .transport(.timedOut),
      .transport(.tls),
      .transport(.connection),
      .transport(.unknown),
      .httpStatus(code: 503),
      .contentType(.missing),
      .contentType(.unsupported),
      .decodingFailure,
      .unsupportedSchemaVersion,
      .missingServers,
      .recordValidation(index: 3, field: .address),
      .recordValidation(index: 3, field: .port),
      .recordValidation(index: 3, field: .method),
      .recordValidation(index: 3, field: .password),
      .recordValidation(index: 3, field: .identity),
      .duplicateIdentity,
      .credential(category: .missing),
      .credential(category: .read),
      .credential(category: .write),
      .commit(category: .persistence, rollback: .notNeeded),
      .commit(category: .credentials, rollback: .restored),
      .commit(category: .persistence, rollback: .incomplete),
      .legacy,
      .unknown,
    ]

    for failure in failures {
      let data = try JSONEncoder().encode(failure)
      XCTAssertEqual(try JSONDecoder().decode(SubscriptionRefreshFailure.self, from: data), failure)
    }
  }

  func testHTTPStatusFailureRoundTripsAsTypedFacts() throws {
    let failure = SubscriptionRefreshFailure.httpStatus(code: 503)

    let data = try JSONEncoder().encode(failure)
    let restored = try JSONDecoder().decode(SubscriptionRefreshFailure.self, from: data)

    XCTAssertEqual(restored, failure)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    XCTAssertFalse(json.contains("reason"))
  }

  func testPartialRollbackIsCoarseAndContainsNoCredentialReferences() throws {
    let failure = SubscriptionRefreshFailure.commit(
      category: .persistence,
      rollback: .incomplete)

    let data = try JSONEncoder().encode(failure)
    let restored = try JSONDecoder().decode(SubscriptionRefreshFailure.self, from: data)

    XCTAssertEqual(restored, failure)
    let json = String(bytes: data, encoding: .utf8) ?? ""
    XCTAssertFalse(json.contains("credential"))
    XCTAssertFalse(json.contains("reference"))
  }

  func testLegacyMigrationFailureHasNoStoredDetail() throws {
    let data = Data(
      #"{"failed":{"at":0,"reason":"https://provider.example/token"}}"#.utf8)

    let status = try JSONDecoder().decode(SubscriptionRefreshStatus.self, from: data)

    guard case .failed(_, let failure) = status else {
      return XCTFail("旧失败字符串应迁移为 failed 状态")
    }
    XCTAssertEqual(failure, .legacy)
  }
}
