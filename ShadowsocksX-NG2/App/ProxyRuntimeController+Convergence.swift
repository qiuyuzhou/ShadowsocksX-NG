import Foundation

/// 一次计划执行的结果:动作是否全部按序成功,以及本次执行占用的并发流
/// 代际。占用代际供收敛票据推进 flow 分量,取代调用方对 execute 内部
/// 「恰好自增一次」时序的依赖(原 `flowGeneration + 1` 手算)。
struct RuntimeExecutionOutcome {
  /// 本次执行占用的 `flowGeneration`。
  let flow: Int
  /// 全部计划动作是否按序成功。
  let succeeded: Bool
}

/// 收敛票据:运行时收敛操作的代际快照。入口捕获三个并发代际,之后每步
/// 推进用它判定「从入口到现在,并发流 / 模式切换 / 运行时派生是否前进了」;
/// 被更新提交或新意图取代的旧收敛不得再变更运行时状态或写契约。
///
/// 各路径校验的代际子集不同:mode 切换的 mode 代际在派生前捕获、派生
/// 代际在派生后推进(派生自身会推进它);rules 部署四个事实全查(含
/// 会话内 agent 意图);目录 / 启动路径只查派生代际。
struct ConvergenceTicket: Equatable {
  /// 票据时效校验覆盖的代际事实子集。
  struct Checks: OptionSet {
    let rawValue: Int
    /// 并发流代际:任何后续 execute 都使票据失效。
    static let flow = Checks(rawValue: 1 << 0)
    /// 模式切换代际。
    static let mode = Checks(rawValue: 1 << 1)
    /// 运行时文档派生代际。
    static let preparation = Checks(rawValue: 1 << 2)
    /// 会话内 agent 意图仍开启。
    static let agentEnabled = Checks(rawValue: 1 << 3)
  }

  /// 并发流代际;每次 execute 之后由调用方以实际占用值推进。
  var flow: Int
  /// 模式切换代际;捕获后不再变化。
  let mode: Int
  /// 运行时文档派生代际;每次派生之后由调用方以当前值推进。
  var preparation: Int
}

extension ProxyRuntimeController {
  /// 以当前代际捕获收敛票据。
  func convergenceTicket() -> ConvergenceTicket {
    ConvergenceTicket(
      flow: flowGeneration, mode: modeChangeGeneration,
      preparation: runtimePreparationGeneration)
  }

  /// 票据是否仍代表当前收敛:`checking` 列出的代际事实全部未前进。
  func convergenceIsCurrent(
    _ ticket: ConvergenceTicket, checking: ConvergenceTicket.Checks
  ) -> Bool {
    var current = true
    if checking.contains(.flow) { current = current && ticket.flow == flowGeneration }
    if checking.contains(.mode) { current = current && ticket.mode == modeChangeGeneration }
    if checking.contains(.preparation) {
      current = current && ticket.preparation == runtimePreparationGeneration
    }
    if checking.contains(.agentEnabled) { current = current && settings.agentEnabled }
    return current
  }
}
