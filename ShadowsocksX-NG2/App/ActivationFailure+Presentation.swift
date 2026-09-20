/// 激活失败的用户可读呈现（spec #21 D3 无静默回退族 + D11）：点名可行动的
/// 事实。节点身份只取前 8 位片段——完整 UUID 无助于辨认且冗长。
extension ActivationFailure {
  var presentedReason: String {
    switch self {
    case .targetNotFound(let target):
      return "活动目标已被删除（\(shortNodeID(target))）"
    case .targetDisabled(let node):
      return "活动目标自身或其分组已被停用（\(shortNodeID(node))）"
    case .targetExpandsToNothing(let target):
      return "活动目标没有可代理的启用服务器（\(shortNodeID(target))）"
    case .invalidLeaf(let node, let reason):
      return "服务器不可用：\(reason.presentedReason)（\(shortNodeID(node))）"
    }
  }
}

extension LeafInvalidationReason {
  var presentedReason: String {
    switch self {
    case .pluginNotProvided(let program):
      return "本版本未提供插件「\(program)」"
    case .credentialUnresolved:
      return "密码或插件参数在钥匙串中缺失"
    case .credentialReadFailed:
      return "密码或插件参数读取失败"
    }
  }
}

private func shortNodeID(_ id: NodeID) -> String {
  String(id.rawValue.prefix(8))
}
