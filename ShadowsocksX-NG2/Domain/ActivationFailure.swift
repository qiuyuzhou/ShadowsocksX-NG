/// 激活失败的点名原因（spec #21 D3 无静默回退族）。激活被拒与活动目标清除
/// 停止共用同一套原因：前者状态完全不动，后者清除目标并发出停止意图。
enum ActivationFailure: Error, Equatable, Sendable {
  /// 活动目标已被删除（或从未存在）。
  case targetNotFound(NodeID)
  /// 目标自身或某祖先被禁用；携带目标→根路径上第一个禁用节点。
  case targetDisabled(NodeID)
  /// 组目标展开后没有有效启用的服务器叶子（空组或全部子叶停用）。
  case targetExpandsToNothing(NodeID)
  /// 展开结果包含无效叶子；携带叶节点与具体原因，激活整体原子拒绝。
  case invalidLeaf(node: NodeID, reason: LeafInvalidationReason)
}

/// 服务器叶子无效的具体原因（点名到可行动的事实）。
enum LeafInvalidationReason: Equatable, Sendable {
  /// 引用本版本未提供的插件程序（真实受管集由 #38 从供应链清单接通）。
  case pluginNotProvided(program: String)
  /// 凭据引用在 Keychain 无对应条目。
  case credentialUnresolved(CredentialReference)
  /// Keychain 读取失败。
  case credentialReadFailed(CredentialReference)
}
