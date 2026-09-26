import Foundation
import XCTest

@testable import ShadowsocksX_NG2

final class ProxyACLTests: XCTestCase {
  func testDirectACLUsesBypassAllAndFixedLocalSafetyRules() {
    let acl = ProxyACLDocument.direct(
      at: URL(fileURLWithPath: "/tmp/ssxng-test/sslocal-active.acl"))

    XCTAssertTrue(acl.isWellFormed)
    XCTAssertTrue(acl.content.hasPrefix("[bypass_all]\n[bypass_list]\n"))
    XCTAssertFalse(acl.content.contains("[proxy_list]"))
    XCTAssertTrue(acl.content.contains("127.0.0.0/8\n"))
    XCTAssertTrue(acl.content.contains("10.0.0.0/8\n"))
    XCTAssertTrue(acl.content.contains("172.16.0.0/12\n"))
    XCTAssertTrue(acl.content.contains("192.168.0.0/16\n"))
    XCTAssertTrue(acl.content.contains("169.254.0.0/16\n"))
    XCTAssertTrue(acl.content.contains("::1/128\n"))
    XCTAssertTrue(acl.content.contains("fe80::/10\n"))
    XCTAssertTrue(acl.content.contains("fc00::/7\n"))
    XCTAssertTrue(acl.content.contains("||localhost\n"))
    XCTAssertTrue(acl.content.contains("||local\n"))
    XCTAssertTrue(acl.content.contains("^[^.]+$\n"))
    XCTAssertFalse(acl.content.contains("100.64.0.0/10"))
  }

  func testACLRejectsChangedDigestAndNonAbsolutePath() {
    let valid = ProxyACLDocument.direct(
      at: URL(fileURLWithPath: "/tmp/ssxng-test/sslocal-active.acl"))
    let badDigest = ProxyACLDocument(
      path: valid.path,
      summary: valid.summary,
      content: valid.content,
      sha256: String(repeating: "0", count: 64))
    let relativePath = ProxyACLDocument(
      path: "sslocal-active.acl",
      summary: valid.summary,
      content: valid.content,
      sha256: valid.sha256)

    XCTAssertFalse(badDigest.isWellFormed)
    XCTAssertFalse(relativePath.isWellFormed)
  }
}
