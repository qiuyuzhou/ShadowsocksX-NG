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
  var kind: Kind

  private enum CodingKeys: String, CodingKey {
    case id, source, enabled, kind
  }

  init(id: NodeID, source: NodeSource, kind: Kind) {
    self.id = id
    self.source = source
    self.kind = kind
  }

  /// Reads the removed `enabled` field from v1/v2 documents only for migration;
  /// its value has no meaning in the current domain model.
  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(NodeID.self, forKey: .id)
    source = try container.decode(NodeSource.self, forKey: .source)
    _ = try container.decodeIfPresent(Bool.self, forKey: .enabled)
    kind = try container.decode(Kind.self, forKey: .kind)
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(id, forKey: .id)
    try container.encode(source, forKey: .source)
    try container.encode(kind, forKey: .kind)
  }
}

extension CatalogEntry {
  /// 行显示名（主窗口侧栏与菜单栏级联共用口径，issue #31）：服务器备注优先、
  /// 回退地址（含订阅 remarks 回退语义）；分组用名称。
  var displayName: String {
    switch kind {
    case .group(let fields):
      return fields.name
    case .server(let fields):
      return fields.remark.isEmpty ? fields.address : fields.remark
    }
  }
}
