/// 服务器叶子字段（spec #21 D3）。密码与插件参数只持凭据引用，秘密值在
/// Keychain；插件程序引用原样保留，本票不做受管集合校验（激活语义 #26）。
struct ServerFields: Codable, Equatable, Sendable {
  var address: String
  var port: Int
  var encryptionMethod: String
  var passwordRef: CredentialReference
  var remark: String
  var pluginProgram: String?
  var pluginOptionsRef: CredentialReference?

  init(
    address: String,
    port: Int,
    encryptionMethod: String,
    passwordRef: CredentialReference,
    remark: String = "",
    pluginProgram: String? = nil,
    pluginOptionsRef: CredentialReference? = nil
  ) {
    self.address = address
    self.port = port
    self.encryptionMethod = encryptionMethod
    self.passwordRef = passwordRef
    self.remark = remark
    self.pluginProgram = pluginProgram
    self.pluginOptionsRef = pluginOptionsRef
  }
}

/// 分组：命名的有序容器，显式持有子节点顺序（CONTEXT.md「Configuration group」）。
struct GroupFields: Codable, Equatable, Sendable {
  var name: String
  var children: [NodeID]

  init(name: String, children: [NodeID] = []) {
    self.name = name
    self.children = children
  }
}

/// 目录树节点：公共字段 + 服务器叶子/分组形态。
struct CatalogEntry: Codable, Equatable, Sendable {
  enum Kind: Codable, Equatable, Sendable {
    case server(ServerFields)
    case group(GroupFields)
  }

  let id: NodeID
  var source: NodeSource
  var enabled: Bool
  var kind: Kind
}
