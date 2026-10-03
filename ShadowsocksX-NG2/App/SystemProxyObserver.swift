import Foundation

/// 系统代理观察/修复策略机（ADR-0022 / issue #73）：收敛、挂起、意图保持、
/// 修复、清理重试、helper 门禁与 cleanup-until-quiet 观察循环的唯一属主。
/// 意图开关、出口可用性与期望配置由组合方以闭包注入，模块不反向依赖控制器；
/// 呈现事实经自身 `objectWillChange` 由运行时 adapter 合入 workflow 再发布链。
/// 底层只依赖 `SystemProxyControlling`、helper 注册缝与网络变化监视。
@MainActor
final class SystemProxyObserver: ObservableObject {
  enum SystemProxyObservationMode: Equatable {
    case stopped
    case enabled
    case cleanup
  }

  /// Current configuration or operation result, independent of persisted intent.
  @Published var systemProxyState: SystemProxyApplicationFacts = .idle
  /// Approval remains actionable even after an off-intent clear failure.
  @Published var systemProxyApprovalRequired = false
  @Published var systemProxyInspection = SystemProxyInspectionFacts()

  var lastDesiredSystemProxyConfiguration: SystemProxyConfiguration?
  var knownSystemProxyServices: Set<SystemProxyServiceIdentifier> = []
  var systemProxyOperationInProgress = false
  var systemProxyStartupInProgress = false
  var systemProxyInitialApplyPending = false
  var systemProxyWasUnavailable = false
  var systemProxyHealthTask: Task<Void, Never>?
  var systemProxyReadGeneration = 0
  var systemProxyObservationMode = SystemProxyObservationMode.stopped
  var systemProxyCleanupRescanRequested = false
  var systemProxyCleanupTask: Task<SystemProxyApplicationFacts, Never>?
  var systemProxyInspectionScheduled = false

  let systemProxy: SystemProxyControlling
  let systemProxyHelper: SystemProxyHelperServicing
  let systemProxyNetworkChangeMonitor: SystemProxyNetworkChangeMonitoring
  /// 宿主 app bundle 缝（生产为 Bundle.main）：LaunchDaemon 清单指纹的定位基准。
  let appBundle: Bundle
  /// 注册清单漂移重注时，注销与重注的间隔（launchd 对节流中 job 的移除异步）。
  let helperRefreshDelayNanoseconds: UInt64
  private let isIntentEnabled: @MainActor () -> Bool
  private let isExitAvailable: @MainActor () -> Bool
  private let desiredConfiguration: @MainActor () -> SystemProxyConfiguration?
  /// 健康观察循环属控制器（循环体含运行时健康呈现），策略机只请求调度。
  private let startSystemProxyHealthObservation: @MainActor () -> Void

  init(
    systemProxy: SystemProxyControlling,
    systemProxyHelper: SystemProxyHelperServicing,
    systemProxyNetworkChangeMonitor: SystemProxyNetworkChangeMonitoring,
    appBundle: Bundle,
    helperRefreshDelayNanoseconds: UInt64,
    isIntentEnabled: @escaping @MainActor () -> Bool,
    isExitAvailable: @escaping @MainActor () -> Bool,
    desiredConfiguration: @escaping @MainActor () -> SystemProxyConfiguration?,
    startSystemProxyHealthObservation: @escaping @MainActor () -> Void
  ) {
    self.systemProxy = systemProxy
    self.systemProxyHelper = systemProxyHelper
    self.systemProxyNetworkChangeMonitor = systemProxyNetworkChangeMonitor
    self.appBundle = appBundle
    self.helperRefreshDelayNanoseconds = helperRefreshDelayNanoseconds
    self.isIntentEnabled = isIntentEnabled
    self.isExitAvailable = isExitAvailable
    self.desiredConfiguration = desiredConfiguration
    self.startSystemProxyHealthObservation = startSystemProxyHealthObservation
  }

  // MARK: - 收敛与应用

  /// Explicit initial application, saved-value changes, or real health recovery.
  /// A healthy GUI startup and passive events only inspect current settings.
  func convergeSystemProxy(forceApply: Bool = false) async {
    guard await waitForSystemProxyOperation() else { return }
    guard isIntentEnabled(), !systemProxyStartupInProgress else { return }
    guard isExitAvailable() else {
      await suspendSystemProxy()
      return
    }
    guard let configuration = desiredConfiguration() else { return }
    let needsApplication =
      forceApply || systemProxyInitialApplyPending || systemProxyWasUnavailable
      || lastDesiredSystemProxyConfiguration != configuration
    if needsApplication {
      await applySystemProxy(configuration, repairing: false)
    } else {
      if systemProxyHelper.status == .approved { _ = await ensureHelperAvailableForApply() }
      await recheckSystemProxy()
    }
  }

  private func applySystemProxy(
    _ configuration: SystemProxyConfiguration, repairing: Bool
  ) async {
    guard !systemProxyOperationInProgress else { return }
    beginSystemProxyOperation()
    defer { endSystemProxyOperation() }
    guard await ensureHelperAvailableForApply() else {
      if !systemProxyState.hasOperationFailure { systemProxyState = .pending }
      updateSystemProxyActions()
      return
    }
    guard isIntentEnabled(), isExitAvailable() else { return }
    if repairing {
      guard await prepareSystemProxyRepair(configuration) else { return }
    }
    systemProxyState = repairing ? .repairing : .applying
    updateSystemProxyActions()
    // Mark the attempt before awaiting: a failed operation is never implicitly retried.
    systemProxyInitialApplyPending = false
    systemProxyWasUnavailable = false
    systemProxyInspection.backgroundUnavailable = false
    lastDesiredSystemProxyConfiguration = configuration
    do {
      if repairing {
        try await systemProxy.repair(configuration)
      } else {
        let outcome = try await systemProxy.apply(configuration)
        if outcome == .unchanged { RuntimeLog.emit(.systemProxyUnchanged) }
      }
      await inspectSystemProxy(configuration: configuration, afterRepair: repairing)
    } catch {
      RuntimeLog.emit(.systemProxyWriteFailed(detail: String(describing: error)))
      systemProxyState =
        repairing
        ? .repairFailed(systemProxyFacts(for: error)) : .failed(systemProxyFacts(for: error))
      await inspectSystemProxy(configuration: configuration, preserveResult: true)
    }
  }

  private func prepareSystemProxyRepair(_ configuration: SystemProxyConfiguration) async -> Bool {
    guard
      await inspectSystemProxy(
        configuration: configuration,
        preserveResult: systemProxyState.hasOperationFailure)
    else { return false }
    guard isIntentEnabled(), isExitAvailable(),
      desiredConfiguration() == configuration, systemProxyHelper.status == .approved
    else { return false }
    guard !systemProxyInspection.differences.isEmpty else {
      systemProxyState = .applied
      return false
    }
    return true
  }

  func repairSystemProxy() async {
    updateSystemProxyActions()
    guard systemProxyInspection.canRepair, let configuration = desiredConfiguration()
    else { return }
    await applySystemProxy(configuration, repairing: true)
  }

  func recheckSystemProxy() async {
    refreshSystemProxyApproval()
    guard isIntentEnabled(), let configuration = desiredConfiguration() else {
      updateSystemProxyActions()
      return
    }
    guard !systemProxyOperationInProgress else { return }
    await inspectSystemProxy(
      configuration: configuration,
      preserveResult: systemProxyState.hasOperationFailure || !isExitAvailable())
    updateSystemProxyActions()
  }

  @discardableResult
  private func inspectSystemProxy(
    configuration: SystemProxyConfiguration, afterRepair: Bool = false,
    preserveResult: Bool = false
  ) async -> Bool {
    systemProxyReadGeneration += 1
    let generation = systemProxyReadGeneration
    do {
      let services = try await systemProxy.readServices()
      guard !services.isEmpty else { throw SystemProxyError.noProxyServices }
      guard generation == systemProxyReadGeneration, isIntentEnabled(),
        desiredConfiguration() == configuration
      else { return false }
      let writes = try SystemProxyPlanner.makeApplyPlan(
        services: services, configuration: configuration
      ).writes
      let differing = Set(writes.map(\.identifier))
      systemProxyInspection.differences = services.compactMap { service in
        guard differing.contains(service.identifier) else { return nil }
        return SystemProxyDifference(
          identifier: service.identifier, name: service.name,
          kind: afterRepair
            ? .remaining
            : (knownSystemProxyServices.contains(service.identifier) ? .changed : .notApplied))
      }
      // Only observed consistency establishes a known service; an unsuccessful write
      // response cannot establish that this app's configuration was ever present.
      knownSystemProxyServices.formUnion(
        services.filter {
          !differing.contains($0.identifier)
        }.map(\.identifier))
      systemProxyInspection.readFailure = nil
      if !preserveResult && !systemProxyState.isClearFailure && !systemProxyWasUnavailable {
        systemProxyState = differing.isEmpty ? .applied : .changed
      }
      return true
    } catch {
      guard generation == systemProxyReadGeneration else { return false }
      systemProxyInspection.differences = []
      systemProxyInspection.readFailure = systemProxyFacts(for: error)
      if !preserveResult && !systemProxyState.isClearFailure && !systemProxyWasUnavailable {
        systemProxyState = .unreadable(systemProxyFacts(for: error))
      }
      return false
    }
  }

  func refreshSystemProxyApproval() {
    systemProxyApprovalRequired =
      systemProxyHelper.status != .approved
      && (isIntentEnabled() || systemProxyState.hasOperationFailure)
  }

  func updateSystemProxyActions() {
    refreshSystemProxyApproval()
    let available = !systemProxyOperationInProgress && !systemProxyApprovalRequired
    systemProxyInspection.canRepair =
      available && isIntentEnabled()
      && isExitAvailable() && systemProxyInspection.readFailure == nil
      && (!systemProxyInspection.differences.isEmpty || systemProxyState.isApplyFailure)
    systemProxyInspection.canRetryClear = available && systemProxyState.isClearFailure
    if systemProxyState.hasOperationFailure {
      startSystemProxyHealthObservation()
    } else if !isIntentEnabled() {
      systemProxyHealthTask?.cancel()
      systemProxyHealthTask = nil
    }
  }

  func suspendSystemProxy() async {
    guard isIntentEnabled(), !systemProxyStartupInProgress else { return }
    guard !systemProxyWasUnavailable else {
      updateSystemProxyActions()
      return
    }
    guard await waitForSystemProxyOperation() else { return }
    guard isIntentEnabled(), !systemProxyWasUnavailable else { return }
    systemProxyWasUnavailable = true
    systemProxyInspection.backgroundUnavailable = true
    systemProxyInitialApplyPending = false
    beginSystemProxyOperation()
    defer { endSystemProxyOperation() }
    let outcome = await clearSystemProxyOutcome()
    systemProxyState = outcome == .idle ? .paused : outcome
    if outcome == .idle {
      systemProxyInspection.differences = []
      systemProxyInspection.readFailure = nil
    }
  }

  func retrySystemProxyClear() async {
    updateSystemProxyActions()
    guard systemProxyInspection.canRetryClear else { return }
    beginSystemProxyOperation()
    defer { endSystemProxyOperation() }
    let outcome = await clearSystemProxyOutcome()
    systemProxyState = outcome == .idle && isIntentEnabled() ? .paused : outcome
  }

  private func beginSystemProxyOperation() {
    systemProxyOperationInProgress = true
    systemProxyInspection.isBusy = true
    systemProxyReadGeneration += 1
    updateSystemProxyActions()
  }

  private func endSystemProxyOperation() {
    systemProxyOperationInProgress = false
    systemProxyInspection.isBusy = false
    updateSystemProxyActions()
  }

  private func waitForSystemProxyOperation() async -> Bool {
    while systemProxyOperationInProgress {
      do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return false }
    }
    return !Task.isCancelled
  }
}

// MARK: - helper 门禁（issue #71）

extension SystemProxyObserver {
  /// helper 可用性门禁（issue #71）：已批准即通过——仅当 LaunchDaemon 清单
  /// 与上次注册时的指纹漂移（app 更新改过清单）才注销重注刷新 launchd 的
  /// job 定义；未注册则尝试注册（注册本身不弹授权框，成功即记指纹）；待批准
  /// 或注册失败时置位批准路径并保持待应用。
  private func ensureHelperAvailableForApply() async -> Bool {
    switch systemProxyHelper.status {
    case .approved:
      if helperRegistrationDrifted() {
        do {
          try systemProxyHelper.unregister()
          // launchd 对节流中（spawn scheduled）job 的移除是异步的：立即重注
          // 会命中尚未移除的旧定义（实测注销重注后定义不变）。等过 minimum
          // runtime（10s）节流窗再重注；间隔内收敛以旧定义失败呈超时。
          try? await Task.sleep(nanoseconds: helperRefreshDelayNanoseconds)
          try systemProxyHelper.register()
          storeHelperRegistrationStamp()
        } catch {
          // 刷新失败不记指纹，下次启动重试；状态退回后由下方分支接手。
          RuntimeLog.emit(.systemProxyHelperRegisterFailed(detail: String(describing: error)))
        }
      }
      if systemProxyHelper.status == .approved {
        systemProxyApprovalRequired = false
        return true
      }
    case .notRegistered:
      do {
        try systemProxyHelper.register()
        storeHelperRegistrationStamp()
      } catch {
        RuntimeLog.emit(.systemProxyHelperRegisterFailed(detail: String(describing: error)))
      }
      if systemProxyHelper.status == .approved {
        systemProxyApprovalRequired = false
        return true
      }
    case .requiresApproval:
      break
    }
    systemProxyApprovalRequired = true
    return false
  }

  private func helperRegistrationDrifted(defaults: UserDefaults = .standard) -> Bool {
    SystemProxyHelperRegistrationStamp.drifted(
      plistData: SystemProxyHelperIdentity.launchDaemonPlistData(in: appBundle),
      storedStamp: defaults.string(forKey: SystemProxyHelperRegistrationStamp.defaultsKey))
  }

  private func storeHelperRegistrationStamp(defaults: UserDefaults = .standard) {
    guard let plistData = SystemProxyHelperIdentity.launchDaemonPlistData(in: appBundle) else {
      return
    }
    defaults.set(
      SystemProxyHelperRegistrationStamp.stamp(plistData),
      forKey: SystemProxyHelperRegistrationStamp.defaultsKey)
  }

  /// Approval continues only an unattempted initial request; failed writes need a user retry.
  func openSystemProxyHelperApproval() async {
    systemProxyHelper.openApprovalPath()
    refreshSystemProxyApproval()
    if systemProxyInitialApplyPending && !systemProxyState.hasOperationFailure {
      await convergeSystemProxy()
    }
    updateSystemProxyActions()
  }

}

// MARK: - 意图保持与清理

extension SystemProxyObserver {
  /// Health/exit loss clears unavailable settings while preserving enabled intent.
  func holdSystemProxyIntent() async {
    if isIntentEnabled() {
      await suspendSystemProxy()
    } else if !systemProxyState.hasOperationFailure {
      systemProxyState = .idle
    }
  }

  /// 无条件清除全部系统代理配置（issue #71）：typed 失败原样呈现，不重试。
  private func clearSystemProxyOutcome() async -> SystemProxyApplicationFacts {
    do {
      try await systemProxy.clear()
      return .idle
    } catch {
      refreshSystemProxyApproval()
      return .clearFailed(systemProxyFacts(for: error))
    }
  }

  func startEnabledSystemProxyObservation() {
    guard systemProxyObservationMode != .enabled else { return }
    systemProxyObservationMode = .enabled
    startSystemProxyHealthObservation()
    systemProxyNetworkChangeMonitor.start { [weak self] change in
      self?.handleSystemProxyNetworkChange(change)
    }
  }

  func clearAndStopSystemProxyObservation() async -> SystemProxyApplicationFacts {
    if let systemProxyCleanupTask { return await systemProxyCleanupTask.value }
    let task = Task { @MainActor [weak self] in
      guard let self else { return SystemProxyApplicationFacts.idle }
      return await self.performSystemProxyCleanupUntilQuiet()
    }
    systemProxyCleanupTask = task
    let result = await task.value
    systemProxyCleanupTask = nil
    return result
  }

  private func performSystemProxyCleanupUntilQuiet() async -> SystemProxyApplicationFacts {
    if systemProxyObservationMode != .enabled {
      systemProxyObservationMode = .cleanup
      systemProxyNetworkChangeMonitor.start { [weak self] change in
        self?.handleSystemProxyNetworkChange(change)
      }
    } else {
      systemProxyObservationMode = .cleanup
    }

    guard await waitForSystemProxyOperation() else { return systemProxyState }
    beginSystemProxyOperation()
    var outcome: SystemProxyApplicationFacts = .idle
    repeat {
      systemProxyCleanupRescanRequested = false
      outcome = await clearSystemProxyOutcome()
      // Let queued SystemConfiguration notifications reach the main actor. Any
      // location/service/proxy change during this cleanup starts another full scan.
      try? await Task.sleep(nanoseconds: 100_000_000)
      await Task.yield()
    } while systemProxyCleanupRescanRequested && !outcome.hasOperationFailure

    systemProxyNetworkChangeMonitor.stop()
    systemProxyHealthTask?.cancel()
    systemProxyHealthTask = nil
    systemProxyObservationMode = .stopped
    systemProxyInspection = SystemProxyInspectionFacts()
    endSystemProxyOperation()
    return outcome
  }

  private func handleSystemProxyNetworkChange(_ change: SystemProxyNetworkChange) {
    switch systemProxyObservationMode {
    case .stopped:
      return
    case .cleanup:
      if !change.isDisjoint(with: [.networkConfiguration, .proxyConfiguration]) {
        systemProxyCleanupRescanRequested = true
      }
    case .enabled:
      guard isIntentEnabled() else { return }
      guard !systemProxyInspectionScheduled else { return }
      systemProxyInspectionScheduled = true
      Task { @MainActor [weak self] in
        await Task.yield()
        guard let self else { return }
        self.systemProxyInspectionScheduled = false
        await self.recheckSystemProxy()
      }
    }
  }

}

// MARK: - 失败事实映射

extension SystemProxyObserver {
  private func systemProxyFacts(for error: Error) -> SystemProxyFailureFacts {
    if let error = error as? SystemProxyError {
      return Self.systemProxyFacts(for: error)
    }
    if let error = error as? ProxyModeError {
      return .mode(error)
    }
    return .unknown
  }

  // 显式映射保持与错误族一一对应；错误带关联值，无法用字典键穷举。
  // swiftlint:disable:next cyclomatic_complexity
  private static func systemProxyFacts(
    for error: SystemProxyError
  ) -> SystemProxyFailureFacts {
    switch error {
    case .preferencesUnavailable: return .operation(.preferencesUnavailable)
    case .preferencesBusy: return .operation(.preferencesBusy)
    case .noCurrentNetworkSet: return .operation(.noCurrentNetworkSet)
    case .noProxyServices: return .operation(.noProxyServices)
    case .unreadableService: return .operation(.unreadableService)
    case .invalidStoredConfiguration: return .operation(.invalidStoredConfiguration)
    case .cannotWriteService: return .operation(.cannotWriteService)
    case .commitFailed: return .operation(.commitFailed)
    case .applyFailed: return .operation(.applyFailed)
    case .noNetworkLocations: return .operation(.noNetworkLocations)
    case .invalidRequest: return .operation(.invalidRequest)
    case .helperUnavailable: return .operation(.helperUnavailable)
    }
  }
}
