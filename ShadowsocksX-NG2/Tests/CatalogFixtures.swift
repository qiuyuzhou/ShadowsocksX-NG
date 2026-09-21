import Foundation

@testable import ShadowsocksX_NG2

/// 测试用内存凭据存储；契约与 Keychain 实现一致。
final class InMemoryCredentialStore: CredentialStoring {
  private var storage: [String: String] = [:]

  var storageCount: Int { storage.count }

  func save(_ secret: String, for reference: CredentialReference) throws {
    storage[reference.rawValue] = secret
  }

  func secret(for reference: CredentialReference) throws -> String? {
    storage[reference.rawValue]
  }

  func delete(_ reference: CredentialReference) throws {
    storage.removeValue(forKey: reference.rawValue)
  }
}

/// 订阅子树夹具：固定分组 + 嵌套分组 + 两个服务器叶子。
struct SubscriptionFixture {
  let catalog: ConfigurationCatalog
  let groupID: NodeID
  let nestedGroupID: NodeID
  let serverIDs: [NodeID]
}

/// 目录树测试夹具。订阅子树在本票仅以夹具形态存在（刷新语义 #35）。
enum CatalogFixtures {
  /// 订阅节点身份采用「订阅前缀:供应商稳定 ID」作用域限定形式。
  static func makeSubscriptionFixture(prefix: String = "sub1") throws -> SubscriptionFixture {
    var catalog = ConfigurationCatalog()
    let groupID = NodeID(rawValue: "\(prefix):group")
    try catalog.addGroup("订阅分组", source: .subscription, id: groupID)
    let nestedGroupID = NodeID(rawValue: "\(prefix):nested-group")
    try catalog.addGroup("嵌套分组", source: .subscription, id: nestedGroupID, to: groupID)
    let serverA = NodeID(rawValue: "\(prefix):server-a")
    try catalog.addServer(
      serverFields(remark: "香港 01"), source: .subscription, id: serverA, to: groupID)
    let serverB = NodeID(rawValue: "\(prefix):server-b")
    try catalog.addServer(
      serverFields(remark: "日本 02"), source: .subscription, id: serverB, to: nestedGroupID)
    return SubscriptionFixture(
      catalog: catalog,
      groupID: groupID,
      nestedGroupID: nestedGroupID,
      serverIDs: [serverA, serverB]
    )
  }

  /// 服务器叶子夹具。地址用文档保留段（RFC 5737），不指向真实主机。
  static func serverFields(remark: String) -> ServerFields {
    ServerFields(
      address: "203.0.113.7",
      port: 8388,
      encryptionMethod: "aes-256-gcm",
      passwordRef: .fresh(),
      remark: remark,
      pluginProgram: "v2ray-plugin",
      pluginOptionsRef: .fresh()
    )
  }
}

/// 测试便捷扩展：省去每次填字段。
extension ConfigurationCatalog {
  @discardableResult
  mutating func addTestServer(
    _ remark: String,
    source: NodeSource = .manual,
    id: NodeID? = nil,
    to parent: NodeID? = nil,
    index: Int? = nil
  ) throws -> NodeID {
    try addServer(
      CatalogFixtures.serverFields(remark: remark), source: source, id: id, to: parent, index: index
    )
  }
}
