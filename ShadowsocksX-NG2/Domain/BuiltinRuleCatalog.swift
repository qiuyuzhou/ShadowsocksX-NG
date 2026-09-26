import Foundation

/// 内置规则目录（issue #63）：从 bundle 资源加载已固定的 geolocation-cn
/// 快照。普通构建只读本地快照，运行时不抓取或转换；快照缺失/损坏/版本
/// 不匹配时加载失败，不生成空规则 ACL。
struct BuiltinRuleCatalog {
  /// 生产加载缝：bundle 内固定快照。
  static func loadGeolocationCN(from bundle: Bundle = .main) throws -> RuleSnapshot {
    guard let url = bundle.url(forResource: "snapshot", withExtension: "json")
    else {
      throw RuleSnapshotError.missing
    }
    return try RuleSnapshotStore(fileURL: url).load()
  }

  /// 供 ACL 编译的中国域名直连候选（`.cn` 后缀 + geolocation-cn）。
  static func chinaDirectRules(from snapshot: RuleSnapshot) -> [ProxyRule] {
    snapshot.rules.filter { $0.action == .direct }
  }
}
