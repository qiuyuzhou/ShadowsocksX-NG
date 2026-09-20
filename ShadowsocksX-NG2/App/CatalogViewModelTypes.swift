import Foundation

/// 侧栏树行快照（由 CatalogViewModel 派生，订阅分组同样入树供浏览）。
struct SidebarNode: Identifiable {
  let id: NodeID
  let name: String
  let isGroup: Bool
  let source: NodeSource
  let enabled: Bool
  let effectivelyEnabled: Bool
  /// 服务器叶子为 `nil`；分组持有子树快照。
  let children: [SidebarNode]?
}

/// 服务器详情表单状态：凭据已解析为明文（仅本窗口内呈现）；插件区只读（#38）。
struct ServerFormState: Equatable {
  let address: String
  let port: Int
  let encryptionMethod: String
  let password: String
  let remark: String
  /// `nil` 即「无插件」；否则显示程序引用与「本版本是否提供」状态（D10）。
  let plugin: PluginDisplay?
  let isEditable: Bool
}

/// 插件区只读展示三要素：程序引用、本版本是否提供、参数是否已配置。
struct PluginDisplay: Equatable {
  let program: String
  let provided: Bool
  let optionsPresent: Bool
}
