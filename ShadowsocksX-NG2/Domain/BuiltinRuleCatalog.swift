import Foundation

/// 内置规则目录（issue #63/#64/#65）：从 bundle 资源加载已固定的 geolocation-cn、
/// china-ipv4 与 gfwlist 快照。普通构建只读本地快照，运行时不抓取或转换；
/// 快照缺失/损坏/版本不匹配时加载失败，不生成空规则 ACL。
struct BuiltinRuleCatalog {
  /// 生产加载缝：bundle 内固定快照（`rules/<source>/snapshot.json`）。
  static func loadGeolocationCN(from bundle: Bundle = .main) throws -> RuleSnapshot {
    try loadSnapshot(named: "geolocation-cn", from: bundle)
  }

  /// china-operator-ip 中国 IPv4 CIDR 直连候选（issue #64）。
  static func loadChinaIPv4(from bundle: Bundle = .main) throws -> RuleSnapshot {
    try loadSnapshot(named: "china-ipv4", from: bundle)
  }

  /// GFWList 代理候选（issue #65）：仅含可准确表达且未被更宽代理规则遮蔽的规则。
  static func loadGFWList(from bundle: Bundle = .main) throws -> RuleSnapshot {
    try loadSnapshot(named: "gfwlist", from: bundle)
  }

  private static func loadSnapshot(named name: String, from bundle: Bundle) throws -> RuleSnapshot {
    // folder reference 保留 `rules/<source>/snapshot.json` 目录结构。
    guard
      let url = bundle.url(
        forResource: "snapshot", withExtension: "json", subdirectory: "rules/\(name)")
    else {
      throw RuleSnapshotError.missing
    }
    return try RuleSnapshotStore(fileURL: url).load()
  }

  /// 供 ACL 编译的中国直连候选（`.cn` 后缀 + geolocation-cn + china-ipv4）。
  static func chinaDirectRules(from snapshot: RuleSnapshot) -> [ProxyRule] {
    snapshot.rules.filter { $0.action == .direct }
  }

  /// 合并多份快照的直连候选；保持输入顺序（域名在前，CIDR 在后）。
  static func chinaDirectRules(from snapshots: [RuleSnapshot]) -> [ProxyRule] {
    snapshots.flatMap { chinaDirectRules(from: $0) }
  }

  /// 供 ACL 编译的 GFWList 候选（issue #65）：可准确表达且未被遮蔽的规则
  /// （代理候选 + 未遮蔽例外），两种动作都参与编译。
  static func gfwlistRules(from snapshot: RuleSnapshot) -> [ProxyRule] {
    snapshot.rules
  }
}
