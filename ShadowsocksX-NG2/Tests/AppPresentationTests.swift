import XCTest

@testable import ShadowsocksX_NG2

/// Presentation edge coverage: typed facts are asserted independently from the
/// wording owned by the App layer, and unknown descriptions never leak through.
final class AppPresentationTests: XCTestCase {
  func testSubscriptionFailureFactsAllHaveSafePresentation() {
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
      .recordValidation(index: 2, field: .address),
      .recordValidation(index: 2, field: .port),
      .recordValidation(index: 2, field: .method),
      .recordValidation(index: 2, field: .password),
      .recordValidation(index: 2, field: .identity),
      .duplicateIdentity,
      .credential(category: .missing),
      .credential(category: .read),
      .credential(category: .write),
      .commit(category: .persistence, rollback: .notNeeded),
      .commit(category: .persistence, rollback: .restored),
      .commit(category: .persistence, rollback: .incomplete),
      .commit(category: .credentials, rollback: .notNeeded),
      .commit(category: .credentials, rollback: .restored),
      .commit(category: .credentials, rollback: .incomplete),
      .legacy,
      .unknown,
    ]

    for failure in failures {
      let message = AppPresentation.message(for: failure)
      XCTAssertFalse(message.isEmpty, "每个 durable failure fact 都应有呈现：\(failure)")
      XCTAssertFalse(message.contains("https://"))
      XCTAssertFalse(message.contains("credential"))
      XCTAssertFalse(message.contains("reference"))
    }

    XCTAssertTrue(
      AppPresentation.message(
        for: .commit(category: .credentials, rollback: .incomplete)
      )
      .contains("恢复不完整"))
  }

  func testRuntimeAndSettingsFactsUseCentralPresentation() {
    let runtimeStates: [ProxyRuntimeController.ProxyState] = [
      .firewallBlocked(FirewallBlockedFacts(executableName: "sslocal")),
      .launchFailed(
        .localEndpoint(endpoint: "SOCKS", host: "127.0.0.1", port: 11086, cause: .refused)),
      .launchFailed(.pacEndpoint(port: 11089, cause: .timedOut)),
      .launchFailed(.missingRuntimeDocument),
      .launchFailed(.unreadableSettings),
      .activationFailed(.noActiveTarget),
      .serviceFailed(.runtimeFile),
      .serviceFailed(.agent),
      .serviceFailed(.missingDocument),
      .serviceFailed(.persistence),
      .serviceFailed(.unknown),
      .systemProxyFailed(.operation(.applyFailed)),
      .systemProxyFailed(.mode(.invalidSOCKSPort(0))),
      .systemProxyFailed(.ownershipConflict),
      .systemProxyFailed(.unknown),
    ]

    for state in runtimeStates {
      let message = AppPresentation.message(for: state)
      XCTAssertFalse(message.isEmpty, "每个 runtime fact 都应有呈现：\(state)")
    }

    let runtimeFailures: [RuntimeFailureFacts] = [
      .firewallBlocked(FirewallBlockedFacts(executableName: "sslocal")),
      .requiresApproval,
    ]
    for failure in runtimeFailures {
      XCTAssertFalse(
        AppPresentation.message(for: failure).isEmpty,
        "每个 typed runtime failure fact 都应有呈现：\(failure)")
    }

    let issues: [SettingsFieldIssue] = [
      .port(.socks, error: .portOutOfRange(endpoint: .socks, port: 0)),
      .advertisedAddress(error: .invalidHostAddress("127.0.0.1")),
      .timeoutSeconds(error: .invalidTimeout(0)),
      .gfwListURL(error: .invalidGFWListURL("not a url")),
    ]
    for issue in issues {
      XCTAssertFalse(AppPresentation.message(for: issue).isEmpty)
    }
  }

  func testUnknownErrorUsesFixedFallback() {
    struct SecretError: Error, CustomStringConvertible {
      var description: String { "secret-token https://provider.example/sub.json" }
    }

    XCTAssertEqual(AppPresentation.message(for: SecretError()), AppPresentation.unknownError)
  }
}
