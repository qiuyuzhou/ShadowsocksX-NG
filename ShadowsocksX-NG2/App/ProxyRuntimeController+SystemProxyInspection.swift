import Foundation

// Current configuration observation and explicit operations (issue #73).
extension ProxyRuntimeController {
  /// Explicit initial application, saved-value changes, or real health recovery.
  /// A healthy GUI startup and passive events only inspect current settings.
  func convergeSystemProxy(forceApply: Bool = false) async {
    guard await waitForSystemProxyOperation() else { return }
    guard settings.systemProxyEnabled, !systemProxyStartupInProgress else { return }
    guard systemProxyExitAvailable else {
      await suspendSystemProxy()
      return
    }
    guard let configuration = desiredSystemProxyConfiguration else { return }
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

  var desiredSystemProxyConfiguration: SystemProxyConfiguration? {
    guard let document = lastDocument else { return nil }
    return try? proxyMode.systemProxyConfiguration(
      for: document, exceptions: settings.proxyExceptionList)
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
    guard settings.systemProxyEnabled, systemProxyExitAvailable else { return }
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
      RuntimeLog.emit(.systemProxyWriteFailed(detail: describe(error)))
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
    guard settings.systemProxyEnabled, systemProxyExitAvailable,
      desiredSystemProxyConfiguration == configuration, systemProxyHelper.status == .approved
    else { return false }
    guard !systemProxyInspection.differences.isEmpty else {
      systemProxyState = .applied
      return false
    }
    return true
  }

  func repairSystemProxy() async {
    updateSystemProxyActions()
    guard systemProxyInspection.canRepair, let configuration = desiredSystemProxyConfiguration
    else { return }
    await applySystemProxy(configuration, repairing: true)
  }

  func recheckSystemProxy() async {
    refreshSystemProxyApproval()
    guard settings.systemProxyEnabled, let configuration = desiredSystemProxyConfiguration else {
      updateSystemProxyActions()
      return
    }
    guard !systemProxyOperationInProgress else { return }
    await inspectSystemProxy(
      configuration: configuration,
      preserveResult: systemProxyState.hasOperationFailure || !systemProxyExitAvailable)
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
      guard generation == systemProxyReadGeneration, settings.systemProxyEnabled,
        desiredSystemProxyConfiguration == configuration
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
      && (settings.systemProxyEnabled || systemProxyState.hasOperationFailure)
  }

  func updateSystemProxyActions() {
    refreshSystemProxyApproval()
    let available = !systemProxyOperationInProgress && !systemProxyApprovalRequired
    systemProxyInspection.canRepair =
      available && settings.systemProxyEnabled
      && systemProxyExitAvailable && systemProxyInspection.readFailure == nil
      && (!systemProxyInspection.differences.isEmpty || systemProxyState.isApplyFailure)
    systemProxyInspection.canRetryClear = available && systemProxyState.isClearFailure
    if systemProxyState.hasOperationFailure {
      startSystemProxyHealthObservation()
    } else if !settings.systemProxyEnabled {
      systemProxyHealthTask?.cancel()
      systemProxyHealthTask = nil
    }
  }

  func suspendSystemProxy() async {
    guard settings.systemProxyEnabled, !systemProxyStartupInProgress else { return }
    guard !systemProxyWasUnavailable else {
      updateSystemProxyActions()
      return
    }
    guard await waitForSystemProxyOperation() else { return }
    guard settings.systemProxyEnabled, !systemProxyWasUnavailable else { return }
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
    systemProxyState = outcome == .idle && settings.systemProxyEnabled ? .paused : outcome
  }

  func beginSystemProxyOperation() {
    systemProxyOperationInProgress = true
    systemProxyInspection.isBusy = true
    systemProxyReadGeneration += 1
    updateSystemProxyActions()
  }

  func endSystemProxyOperation() {
    systemProxyOperationInProgress = false
    systemProxyInspection.isBusy = false
    updateSystemProxyActions()
  }

  func waitForSystemProxyOperation() async -> Bool {
    while systemProxyOperationInProgress {
      do { try await Task.sleep(nanoseconds: 10_000_000) } catch { return false }
    }
    return !Task.isCancelled
  }
}
