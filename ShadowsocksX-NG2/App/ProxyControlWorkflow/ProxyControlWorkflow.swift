import Combine
import Foundation

// MARK: - Snapshot 投影

/// 可安全复制的 HTTP 导出能力（issue #47）：shell 可直接 source 的 http/https
/// 双导出行。原始监听设置与内部端口语义不进 snapshot。复制是 UI 的副作用，
/// workflow 不触剪贴板。
struct HTTPExportCapability: Equatable, Sendable {
  /// 已就绪的导出行（UI 原样复制，不自行拼装）。
  let copyableLine: String
}

/// 活动目标安全事实（issue #47）：存在性 + 可展示路径摘要。身份是不透明
/// `NodeID`（级联勾选用）；不含凭据、原始配置 URL 或目录树结构。路径摘要
/// 是目录 projection 的显示名（无备注的服务器叶子以地址为显示名，与目录树
/// 呈现一致），不额外携带配置细节。
struct ProxyActiveTargetFacts: Equatable, Sendable {
  let id: NodeID
  /// 根 → 叶显示名路径（" / " 连接）；目标已不在当前目录树中为 nil。
  let pathSummary: String?
}

/// 代理控制的统一 UI-facing snapshot（issue #47）：一次 workflow observation
/// 产出的整体安全投影，所有字段来自同一时间点。不含控制器内部状态枚举、
/// `ProxySettings`、完整目录树、凭据、原始 URL、原始日志或本地化文案；
/// 失败保持 typed facts，成句呈现由 App presentation edge 负责。
struct ProxyControlSnapshot: Equatable, Sendable {
  /// 固定运行时事实：状态类别、开关意图与 typed 失败。
  let runtime: ProxyRuntimeFacts
  /// 当前已应用的代理模式（持久化成功的模式）。
  let proxyMode: ProxyMode
  /// 可用模式（issue #46 Domain 单点策略的投影；UI 不再自行判断可用性）。
  let availableModes: [ProxyMode]
  /// 活动目标事实；无活动目标为 nil。
  let activeTarget: ProxyActiveTargetFacts?
  /// 最近一次激活预检或目录收敛跳过的无效服务器数量。
  let skippedInvalidServerCount: Int
  /// HTTP 导出能力。
  let httpExport: HTTPExportCapability
}

// MARK: - 适配缝

/// 生产运行时适配缝（issue #47）：包装现有 `ProxyRuntimeController` 的能力
/// 与观察。不复制状态机、generation 与健康门禁；持久化先行、失败恢复与系统
/// 代理 ownership 语义全部留在控制器。测试注入确定性 fake（story 31）。
@MainActor
protocol ProxyRuntimeAdapting: AnyObject {
  /// 固定运行时事实（状态类别 + 开关意图 + typed 失败）。
  var runtimeFacts: ProxyRuntimeFacts { get }
  /// 当前已应用的代理模式。
  var proxyMode: ProxyMode { get }
  /// 最近一次激活预检或目录收敛跳过的无效服务器数量。
  var skippedInvalidServerCount: Int { get }
  /// 当前活动目标身份；无目标为 nil（目录侧目标事实的唯一输入）。
  var activeTargetID: NodeID? { get }
  /// 可安全复制的 HTTP 导出能力。
  var httpExportCapability: HTTPExportCapability { get }
  /// 运行时事实变化通知：目录驱动、设置变更或运行时收敛导致事实变化后
  /// 发值。生产实现带主队列 hop（willChange 语义 → didChange 读取）；
  /// fake 同步发值。workflow 以此触发整体重观察。
  var changes: AnyPublisher<Void, Never> { get }

  /// 启动重同步（GUI 重启后的注册态重校验）。
  func resyncOnLaunch() async
  func setProxyEnabled(_ enabled: Bool) async
  func setProxyMode(_ mode: ProxyMode) async
}

/// 窄的目录目标事实缝（issue #47，story 28）：目录侧只向代理控制提供活动
/// 目标的存在性与安全路径摘要；完整目录树、订阅对象与凭据不出此接口。
@MainActor
protocol ProxyTargetFactsReading: AnyObject {
  /// 活动目标安全事实：无活动目标为 nil；目标不在当前目录树中时摘要为 nil。
  func activeTargetFacts(for targetID: NodeID?) -> ProxyActiveTargetFacts?
}

// MARK: - Workflow

/// 代理控制工作流 module（issue #47）：状态菜单与未来主窗口共用的唯一
/// UI-facing 代理控制 seam。围绕现有 `ProxyRuntimeController` 建立稳定
/// typed interface：整体发布的 `ProxyControlSnapshot` 与 typed async
/// commands；命令完成后重新发布完整 snapshot，预期运行时失败以
/// `RuntimeFailureFacts` 进入 snapshot。不拆分控制器，也不持有第二套运行时
/// 状态机；活动目标树、目标激活与订阅刷新仍由 CatalogWorkflow 负责，安全
/// 诊断与导出仍由 DiagnosticsWorkflow 负责。
@MainActor
final class ProxyControlWorkflow: ObservableObject {
  /// 最新整体 snapshot（唯一读取面；每次观察整体替换）。
  @Published private(set) var snapshot: ProxyControlSnapshot

  private let runtime: any ProxyRuntimeAdapting
  private let targetFacts: any ProxyTargetFactsReading
  private var cancellables: Set<AnyCancellable> = []

  init(runtime: any ProxyRuntimeAdapting, targetFacts: any ProxyTargetFactsReading) {
    self.runtime = runtime
    self.targetFacts = targetFacts
    snapshot = Self.makeSnapshot(runtime: runtime, targetFacts: targetFacts)
    runtime.changes
      .sink { [weak self] _ in self?.republish() }
      .store(in: &cancellables)
  }

  // MARK: - 观察与命令

  /// 启动观察：GUI 重启后的注册态重校验 + 整体重发布（组合根在启动时调用）。
  func resyncOnLaunch() async {
    await runtime.resyncOnLaunch()
    republish()
  }

  /// 启用/停用代理：命令完成后返回并发布完整新 snapshot。
  @discardableResult
  func setProxyEnabled(_ enabled: Bool) async -> ProxyControlSnapshot {
    await runtime.setProxyEnabled(enabled)
    return republish()
  }

  /// 切换代理模式：可用性与 no-op 语义由控制器既有入口裁定（issue #46）；
  /// 完成后整体重发布。持久化失败保留旧模式，失败以 typed fact 呈现。
  @discardableResult
  func setProxyMode(_ mode: ProxyMode) async -> ProxyControlSnapshot {
    await runtime.setProxyMode(mode)
    return republish()
  }

  // MARK: - 整体观察（implementation，UI 不可见）

  /// 一次 observation 内整体拼装 snapshot；任何单一事实变化后整体替换，
  /// 不暴露「新模式配旧状态」的混合结果。
  @discardableResult
  private func republish() -> ProxyControlSnapshot {
    snapshot = Self.makeSnapshot(runtime: runtime, targetFacts: targetFacts)
    return snapshot
  }

  private static func makeSnapshot(
    runtime: any ProxyRuntimeAdapting,
    targetFacts: any ProxyTargetFactsReading
  ) -> ProxyControlSnapshot {
    ProxyControlSnapshot(
      runtime: runtime.runtimeFacts,
      proxyMode: runtime.proxyMode,
      availableModes: ProxyMode.availableModes,
      activeTarget: targetFacts.activeTargetFacts(for: runtime.activeTargetID),
      skippedInvalidServerCount: runtime.skippedInvalidServerCount,
      httpExport: runtime.httpExportCapability)
  }
}
