import Combine
import Foundation

/// 已提交目录的内存快照（issue #40）：协调器与运行时缝之间的传值。运行时
/// 收敛以此为唯一目标，不回读磁盘；磁盘仍是重启与跨进程恢复的权威来源。
struct CommittedCatalogSnapshot: Equatable, Sendable {
  let catalog: ConfigurationCatalog
  let subscriptions: [SubscriptionRecord]
}

/// 目录提交后一次运行时收敛的结构化结果（issue #40）。协调器不生成本地化
/// 文案：失败细节原样携带平台运行时给出的点名事实，由上层 presentation 决定
/// 如何呈现。
enum RuntimeSyncOutcome: Equatable, Sendable {
  /// 代理未开启：活动目标已按提交快照重校验，未部署。
  case revalidated
  /// 运行时已向提交快照收敛（部署已执行且启动健康通过）。
  case converged(skippedServers: [SkippedServer])
  /// 部署已执行但运行时未收敛；细节为平台运行时的点名事实（nil 表示等待
  /// 用户在系统设置批准等无额外细节的终态）。
  case failed(detail: String?)
  /// 活动目标失效：目标已清除且代理已停止（无静默回退）。
  case clearedAndStopped(ActivationFailure)
}

/// 运行时收敛的可观察阶段（issue #40）：目录已提交 → 运行时同步中 → 结束。
/// generation 为提交代次；被更新提交取代的旧代次不写最终状态。
enum RuntimeSyncStatus: Equatable {
  /// 无进行中或已完成的同步（无活动目标时提交保持此状态）。
  case idle
  /// 正在向该代次提交快照收敛。
  case syncing(generation: Int)
  /// 该代次收敛已结束。
  case finished(generation: Int, outcome: RuntimeSyncOutcome)
}

/// 运行时同步缝（issue #40）：目录提交协调器与代理运行时之间的窄接口。
/// 生产实现适配现有代理运行时控制器；测试注入确定性 fake。
@MainActor
protocol CatalogRuntimeSyncing: AnyObject {
  /// 当前是否存在活动目标（无目标时目录提交不驱动运行时）。
  var hasActiveTarget: Bool { get }
  /// 让运行时向刚提交的目录快照收敛。健康检查、LaunchAgent 与端点启动的
  /// 耗时属于本调用的异步收敛阶段。
  func converge(to snapshot: CommittedCatalogSnapshot) async -> RuntimeSyncOutcome
}

/// 目录提交—运行时同步协调器（issue #40）：普通配置变更的唯一提交入口。
/// 管线为「副本变更 → 校验并原子持久化 → 发布已提交状态 → 异步运行时收敛」；
/// 目录提交在持久化成功后立即完成，不因运行时失败回滚目录，也不被健康检查
/// 或启动耗时阻塞。每次提交递增代次：旧代次自然结束，但不得覆盖最新代次的
/// 最终状态；没有自动重试，后续提交、显式激活或启动代理会发起新的同步尝试。
@MainActor
final class CatalogCommitCoordinator: ObservableObject {
  /// 最新提交的运行时收敛阶段（结构化；呈现由上层决定）。
  @Published private(set) var syncStatus: RuntimeSyncStatus = .idle

  let fileStore: CatalogFileStore
  private let runtime: CatalogRuntimeSyncing
  /// 提交代次：每次提交递增，用于丢弃被更新提交取代的旧同步结果。
  private var generation = 0

  /// 已提交状态（协调器持有的内存快照；`commit` 成功后整体替换）。
  private(set) var committedCatalog: ConfigurationCatalog
  private(set) var committedSubscriptions: [SubscriptionRecord]

  init(fileStore: CatalogFileStore, runtime: CatalogRuntimeSyncing) {
    self.fileStore = fileStore
    self.runtime = runtime
    (committedCatalog, committedSubscriptions) = Self.loadCommitted(from: fileStore)
  }

  /// 普通目录变更的唯一提交管线。任一同步步骤失败则已提交状态不动并原样
  /// 上抛（凭据等外部副作用由调用方回滚）；运行时收敛在持久化成功后异步开始。
  func commit<T>(
    _ mutate: (inout ConfigurationCatalog, inout [SubscriptionRecord]) throws -> T
  ) throws -> T {
    var workingCatalog = committedCatalog
    var workingSubscriptions = committedSubscriptions
    let result = try mutate(&workingCatalog, &workingSubscriptions)
    try fileStore.save(
      CatalogDocument(catalog: workingCatalog, subscriptions: workingSubscriptions))
    committedCatalog = workingCatalog
    committedSubscriptions = workingSubscriptions
    scheduleRuntimeSync(
      CommittedCatalogSnapshot(catalog: workingCatalog, subscriptions: workingSubscriptions))
    return result
  }

  /// Legacy 导入等独立路径直接落盘后对齐已提交状态；不触发运行时收敛
  /// （导入的运行时边界由独立路径自行驱动，不经普通提交管线）。
  func reloadCommittedStateFromStore() {
    (committedCatalog, committedSubscriptions) = Self.loadCommitted(from: fileStore)
  }

  /// 异步收敛调度：无活动目标不调用运行时；同步开始前与结束后都以代次
  /// 校验——被更新提交取代的旧同步直接结束或丢弃结果，不覆盖最新状态。
  private func scheduleRuntimeSync(_ snapshot: CommittedCatalogSnapshot) {
    generation += 1
    let generation = generation
    guard runtime.hasActiveTarget else {
      syncStatus = .idle
      return
    }
    syncStatus = .syncing(generation: generation)
    Task { @MainActor [weak self] in
      guard let self, self.generation == generation else { return }
      let outcome = await self.runtime.converge(to: snapshot)
      guard !Task.isCancelled, self.generation == generation else { return }
      self.syncStatus = .finished(generation: generation, outcome: outcome)
    }
  }

  /// 磁盘读取的容错口径与首次加载一致：损坏文档回退全新空文档，等待
  /// 用户经由导入/设置路径修复。
  private static func loadCommitted(
    from fileStore: CatalogFileStore
  ) -> (catalog: ConfigurationCatalog, subscriptions: [SubscriptionRecord]) {
    let loaded = (try? fileStore.load()) ?? CatalogDocument()
    return (loaded.catalog, loaded.subscriptions)
  }
}

/// 生产运行时适配器（issue #40）：协调器与现有代理运行时控制器之间的唯一
/// 生产接线，由应用组合根建立。
@MainActor
final class ProxyRuntimeSyncAdapter: CatalogRuntimeSyncing {
  private let controller: ProxyRuntimeController

  init(controller: ProxyRuntimeController) {
    self.controller = controller
  }

  var hasActiveTarget: Bool { controller.isActiveTargetPresent }

  func converge(to snapshot: CommittedCatalogSnapshot) async -> RuntimeSyncOutcome {
    await controller.catalogDidCommit(snapshot: snapshot.catalog)
  }
}
