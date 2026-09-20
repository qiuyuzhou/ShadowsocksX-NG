import XCTest

@testable import ShadowsocksX_NG2

/// 凭据存储缝：Keychain 写入/读出一致（票 #25 验收项）。
final class KeychainCredentialStoreTests: XCTestCase {
  private var service: String!
  private var store: KeychainCredentialStore!

  override func setUpWithError() throws {
    try super.setUpWithError()
    // 每个用例独立 service 命名空间：避免并行/重复运行互相污染
    service = "test.ShadowsocksX-NG2.credentials.\(UUID().uuidString)"
    store = KeychainCredentialStore(service: service)
  }

  override func tearDown() {
    // 按 service 整体清理本用例创建的全部条目
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: service as Any,
    ]
    SecItemDelete(query as CFDictionary)
    super.tearDown()
  }

  func testSaveThenReadIsConsistent() throws {
    let reference = CredentialReference.fresh()
    let secret = "s3cret-密码-🔑"

    try store.save(secret, for: reference)

    XCTAssertEqual(try store.secret(for: reference), secret)
  }

  func testSaveOverwritesExistingSecret() throws {
    let reference = CredentialReference.fresh()

    try store.save("旧密码", for: reference)
    try store.save("新密码", for: reference)

    XCTAssertEqual(try store.secret(for: reference), "新密码")
  }

  func testAbsentReferenceReadsAsNil() throws {
    XCTAssertNil(try store.secret(for: CredentialReference.fresh()))
  }

  func testDeleteRemovesSecretAndIsIdempotent() throws {
    let reference = CredentialReference.fresh()
    try store.save("s", for: reference)

    try store.delete(reference)

    XCTAssertNil(try store.secret(for: reference))
    XCTAssertNoThrow(try store.delete(reference), "删除不存在的条目不报错")
  }

  func testDistinctReferencesDoNotCollide() throws {
    let first = CredentialReference.fresh()
    let second = CredentialReference.fresh()

    try store.save("A", for: first)
    try store.save("B", for: second)

    XCTAssertEqual(try store.secret(for: first), "A")
    XCTAssertEqual(try store.secret(for: second), "B")
  }
}

final class InMemoryCredentialStoreTests: XCTestCase {
  func testContractMatchesKeychainSemantics() throws {
    let store = InMemoryCredentialStore()
    let reference = CredentialReference.fresh()

    XCTAssertNil(try store.secret(for: reference))
    try store.save("x", for: reference)
    XCTAssertEqual(try store.secret(for: reference), "x")
    try store.save("y", for: reference)
    XCTAssertEqual(try store.secret(for: reference), "y")
    try store.delete(reference)
    XCTAssertNil(try store.secret(for: reference))
    try store.delete(reference)
  }
}
