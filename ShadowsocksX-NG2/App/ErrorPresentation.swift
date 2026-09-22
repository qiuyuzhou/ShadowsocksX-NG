import Foundation

/// 错误 → 用户可读文案（主窗口弹窗呈现）。领域拒绝逐条点名原因，与 spec #21
/// 的「无静默回退、点名失败」语义一致。
extension Error {
  var presentableMessage: String {
    switch self {
    case let error as CatalogError:
      return error.presentedMessage
    case let error as ServerFormError:
      switch error {
      case .invalidAddress:
        return "服务器地址不能为空"
      case .invalidPort:
        return "端口必须是 1–65535 之间的整数"
      case .missingEncryptionMethod:
        return "必须选择加密方法"
      case .unsupportedEncryptionMethod(let method):
        return "当前 sslocal 不支持加密方法「\(method)」"
      case .invalidPassword:
        return "密码不能为空"
      case .emptyName:
        return "名称不能为空"
      case .pluginNotManaged(let program):
        return "本版本未提供插件「\(program)」"
      }
    case let error as SsUriError:
      switch error {
      case .notSsUri:
        return "不是 ss:// 链接"
      case .malformed(let detail):
        return "无法解析 ss:// 链接：\(detail)"
      }
    case let error as CredentialStoreError:
      switch error {
      case .keychainStatus(let status):
        return "钥匙串操作失败（错误码 \(status)）"
      case .secretNotUTF8:
        return "钥匙串中的凭据不是文本"
      }
    case let error as SubscriptionFormError:
      switch error {
      case .invalidURL:
        return "订阅地址必须是有效的 HTTPS URL"
      case .notFound:
        return "订阅不存在（可能已被删除）"
      }
    case let error as SubscriptionFetchError:
      return error.presentedMessage
    case let error as SubscriptionParseError:
      return error.presentedMessage
    default:
      return String(describing: self)
    }
  }
}

extension CatalogError {
  var presentedMessage: String {
    switch self {
    case .nodeNotFound:
      return "节点不存在（可能已被删除）"
    case .parentNotFound:
      return "目标分组不存在"
    case .parentNotAGroup:
      return "目标位置不是分组"
    case .notAServer:
      return "该节点不是服务器"
    case .notAGroup:
      return "该节点不是分组"
    case .duplicateID:
      return "节点身份冲突"
    case .crossSourcePlacement(_, let container):
      return container == .subscription
        ? "不能把手动节点移入订阅子树"
        : "不能把订阅节点移入手动子树"
    case .subscriptionNodeImmutable:
      return "订阅节点由远端管理：结构、连接字段与名称只读"
    case .subscriptionServerAtRoot:
      return "订阅服务器不能移出其订阅分组"
    case .cycleDetected:
      return "不能把分组移动进它自己的子树"
    case .indexOutOfRange:
      return "插入位置超出范围"
    case .invalidStructure:
      return "配置目录结构不一致"
    }
  }
}

extension SubscriptionFetchError {
  var presentedMessage: String {
    switch self {
    case .invalidURL:
      return "订阅地址无效（缺少主机）"
    case .unsupportedScheme:
      return "订阅地址必须是 HTTPS"
    case .insecureRedirect:
      return "订阅地址重定向到了非 HTTPS 站点，已拒绝"
    case .transport(let detail):
      return "订阅获取失败（\(detail)）"
    case .httpStatus(let code):
      return "订阅服务器返回 HTTP \(code)"
    case .contentType(let received):
      return received.map { "订阅响应类型不是 application/json; charset=utf-8（收到 \($0)）" }
        ?? "订阅响应缺少 Content-Type: application/json; charset=utf-8"
    }
  }
}

extension SubscriptionParseError {
  var presentedMessage: String {
    switch self {
    case .decodingFailure:
      return "订阅内容不是合法的 SIP-008 JSON 文档"
    case .unsupportedSchemaVersion:
      return "订阅文档版本不受支持（需要 SIP-008 version 1）"
    case .missingServers:
      return "订阅文档缺少 servers 列表"
    case .recordValidation(let index, let reason):
      return "订阅第 \(index + 1) 条服务器记录无效：\(reason)"
    case .duplicateServerID(let id):
      return "订阅包含重复的服务器 ID：\(id)"
    }
  }
}
