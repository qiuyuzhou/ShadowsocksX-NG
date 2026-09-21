import Foundation

/// 受管插件提供缝（spec #21 D10，CONTEXT.md「Managed plugin」）：给定服务器
/// 持有的插件程序引用，返回本版本提供的 bundle 内绝对路径；返回 nil 即
/// 「本版本未提供」，该引用使叶子成为无效激活候选（激活点名拒绝）。
protocol ManagedPluginProviding {
  func executablePath(forProgram program: String) -> String?
}

/// 受管插件静态事实（#38）：来源项目、许可证、固定版本与重签标识，供编辑器
/// 插件区与诊断导出展示。事实只随发版变更（D6「升级前重做静态清单」）：新增
/// 或升级插件须同步 `Vendor/<name>/manifest.json` 与锚点测试
/// `ManagedPluginCatalogTests`，两处漂移即构建期失败。
struct ManagedPluginInfo: Equatable, Sendable {
  /// SIP003 程序名，同时是 bundle 内二进制名与目录里的引用键。
  let program: String
  /// 来源项目（GitHub owner/repo）。
  let project: String
  let projectURL: String
  /// 固定版本 tag（禁止 latest 漂移）。
  let release: String
  let license: String
  /// 构建期 Developer ID 重签的 identifier（`<bundle-id>.plugin.<name>`）。
  let signIdentifier: String
}

/// 本版本受管集（D10）：首版仅 v2ray-plugin v1.3.2；shadow-tls、Cloak 暂缓，
/// simple-obfs、kcptun、GoQuiet、simple-tls 明确不支持（「不支持某插件」是
/// 显式产品状态，不是可扩展的用户自备通道）。
enum ManagedPluginCatalog {
  static let plugins: [ManagedPluginInfo] = [
    ManagedPluginInfo(
      program: "v2ray-plugin",
      project: "shadowsocks/v2ray-plugin",
      projectURL: "https://github.com/shadowsocks/v2ray-plugin",
      release: "v1.3.2",
      license: "MIT",
      signIdentifier: "com.qiuyuzhou.ShadowsocksX-NG.plugin.v2ray-plugin")
  ]

  static func info(forProgram program: String) -> ManagedPluginInfo? {
    plugins.first { $0.program == program }
  }
}

/// 生产实现：受管集内且 bundle 内可执行文件在位才返回绝对路径。D10——GUI
/// 仅在生成配置时检查可执行文件存在，运行时不逐次哈希复验（bundle 签名 +
/// 公证即信任边界）；受管集外引用一律视为「本版本未提供」，路径只从静态表
/// 派生，不拼接任何用户输入。
struct BundleManagedPluginProvider: ManagedPluginProviding {
  /// 插件宿主 bundle 根；生产为应用 bundle，测试注入临时目录。
  var bundleURL: URL = Bundle.main.bundleURL
  var fileManager: FileManager = .default

  func executablePath(forProgram program: String) -> String? {
    guard let info = ManagedPluginCatalog.info(forProgram: program) else { return nil }
    let url =
      bundleURL
      .appendingPathComponent("Contents/Helpers/Plugins")
      .appendingPathComponent(info.program)
    guard fileManager.isExecutableFile(atPath: url.path) else { return nil }
    return url.path
  }
}

/// 显式「本版本什么都不提供」的实现（测试与不涉插件的场景注入用）：任何插件
/// 引用都是无效激活候选（点名原因），不是静默失败。
struct NoManagedPluginProvider: ManagedPluginProviding {
  func executablePath(forProgram program: String) -> String? { nil }
}
