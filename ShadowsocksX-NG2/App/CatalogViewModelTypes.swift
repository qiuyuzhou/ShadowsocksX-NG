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

/// 服务器详情表单状态：凭据已解析为明文（仅本窗口内呈现）；插件区为受管
/// 选择器（issue #38，D10）。
struct ServerFormState: Equatable {
  let address: String
  let port: Int
  let encryptionMethod: String
  let password: String
  let remark: String
  let plugin: PluginSectionState
  let isEditable: Bool
}

/// 插件选择器选中态（D10）：「无」、受管集内程序、受管集外引用。集外引用
/// （Legacy 导入或订阅带入）以显式「本版本未提供」状态呈现并原样保留。
/// Hashable 以直接充当 SwiftUI Picker 的选中值。
enum PluginSelection: Hashable {
  case none
  case managed(program: String)
  case unknown(program: String)
}

/// 插件区表单状态：选中态、受管事实表、提供事实与参数明文（编辑面）。
struct PluginSectionState: Equatable {
  let selection: PluginSelection
  /// 本版本受管集（「无」不由这里提供）。
  let managed: [ManagedPluginInfo]
  /// 当前受管引用的可执行文件是否在位（生成配置时的存在性检查事实）。
  let provided: Bool
  /// 参数是否已配置（存于钥匙串）。
  let optionsPresent: Bool
  /// 参数明文（仅受管选中态解析，供参数输入框预填；其余为空串）。
  let options: String
}
