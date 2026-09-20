import Foundation

/// 订阅源记录（spec #21 D4，issue #9/#35）：持久不透明的订阅 UUID + 固定分组
/// 身份 + 订阅 URL 凭据引用 + 最近刷新状态。URL 是敏感信息，权威副本在凭据
/// 存储（D5），目录文档只持引用；编辑 URL 保留订阅与固定分组身份。
struct SubscriptionRecord: Codable, Equatable, Sendable, Identifiable {
  /// 订阅源身份；删除后新建即新身份（CONTEXT.md「Subscription」）。
  let id: NodeID
  /// 固定订阅分组的稳定身份（客户端所有，跨刷新与 URL 编辑不变）。
  let groupID: NodeID
  var urlRef: CredentialReference
  var status: SubscriptionRefreshStatus
}

/// 最近一次刷新结果。失败原因不含订阅 URL（D5 脱敏）。
enum SubscriptionRefreshStatus: Codable, Equatable, Sendable {
  case never
  case succeeded(at: Date)
  case failed(at: Date, reason: String)
}

/// 配置目录持久化文档的完整形态：结构树 + 订阅源记录。两者一次原子落盘，
/// 保证「订阅记录 ↔ 固定分组子树」跨文档一致。
struct CatalogDocument: Equatable, Sendable {
  var catalog: ConfigurationCatalog
  var subscriptions: [SubscriptionRecord]

  init(
    catalog: ConfigurationCatalog = ConfigurationCatalog(),
    subscriptions: [SubscriptionRecord] = []
  ) {
    self.catalog = catalog
    self.subscriptions = subscriptions
  }
}

/// 已解析为目录形态的订阅快照：身份已按订阅作用域限定、凭据引用已分配
/// （服务层在提交前把明文密码写入凭据存储并构造 `ServerFields`）。
/// `root` 是固定分组的内容来源；固定分组自身身份由应用入口的 `groupID`
/// 决定（客户端所有），`root.id` 不参与挂载。
struct CatalogSubscriptionSnapshot: Equatable, Sendable {
  struct ServerLeaf: Equatable, Sendable {
    let id: NodeID
    var fields: ServerFields
  }

  /// 有序子引用：顺序即快照（远端权威）的用户可见顺序。
  enum Child: Equatable, Sendable {
    case group(Group)
    case server(ServerLeaf)
  }

  struct Group: Equatable, Sendable {
    let id: NodeID
    let name: String
    var children: [Child]
  }

  /// 固定分组显示名：远端根分组名，扩展缺失时为 URL host。
  let name: String
  let root: Group
}
