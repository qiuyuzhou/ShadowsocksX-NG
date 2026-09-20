/// 受管插件提供缝（spec #21 D10，CONTEXT.md「Managed plugin」）：给定服务器
/// 持有的插件程序引用，返回本版本提供的 bundle 内绝对路径；返回 nil 即
/// 「本版本未提供」，该引用使叶子成为无效激活候选。真实受管集由 #38 接通。
protocol ManagedPluginProviding {
  func executablePath(forProgram program: String) -> String?
}

/// #27 的生产占位：#38 从供应链清单接通前，本版本一律不提供插件——引用
/// 插件的服务器是显式无效激活候选（点名原因），不是静默失败。
struct NoManagedPluginProvider: ManagedPluginProviding {
  func executablePath(forProgram program: String) -> String? { nil }
}
