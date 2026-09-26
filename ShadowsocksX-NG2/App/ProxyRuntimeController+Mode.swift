import Foundation

extension ProxyRuntimeController {
  /// The choice persists with the settings snapshot. Direct-mode transitions
  /// also deploy and verify the ACL-backed runtime even when system proxy is off,
  /// because manually connected SOCKS and HTTP clients use the same ACL.
  func setProxyMode(_ mode: ProxyMode) async {
    guard ProxyMode.availableModes.contains(mode) else { return }
    guard mode != proxyMode else { return }
    let previousSettings = settings
    let previousMode = proxyMode
    let previousDocument = lastDocument
    let previousState = state
    var next = settings
    next.preferredMode = mode.kind
    do {
      try settingsStore.save(next)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
      state = .serviceFailed(.persistence)
      return
    }
    settings = next
    proxyMode = mode
    modeChangeGeneration += 1
    let generation = modeChangeGeneration

    guard settings.agentEnabled, state != .off,
      let currentDocument = lastDocument ?? runtimeFileStore.loadDocument()
    else {
      if settings.systemProxyEnabled { systemProxyState = .pending }
      return
    }

    let nextDocument = runtimeDocument(currentDocument, for: mode)
    guard nextDocument.aclRuntime != currentDocument.aclRuntime else {
      guard settings.systemProxyEnabled else { return }
      state = .starting
      _ = await presentLaunchHealth(nextDocument)
      return
    }

    await deployModeTransition(
      nextDocument,
      previousMode: previousMode,
      previousDocument: previousDocument ?? currentDocument,
      previousState: previousState,
      previousSystemProxyEnabled: previousSettings.systemProxyEnabled,
      generation: generation)
  }

  func runtimeDocument(
    _ document: SslocalRuntimeDocument,
    for mode: ProxyMode
  ) -> SslocalRuntimeDocument {
    guard mode == .direct else { return document.replacingACL(nil) }
    return document.replacingACL(.direct(at: runtimeFileStore.aclFileURL))
  }

  private func deployModeTransition(
    _ document: SslocalRuntimeDocument,
    previousMode: ProxyMode,
    previousDocument: SslocalRuntimeDocument,
    previousState: AgentRunState,
    previousSystemProxyEnabled: Bool,
    generation: Int
  ) async {
    guard generation == modeChangeGeneration else { return }
    lastDocument = document
    state = .starting
    guard await execute(.run(document), document: document) else {
      guard generation == modeChangeGeneration else { return }
      await restoreModeTransition(
        previousMode: previousMode,
        previousDocument: previousDocument,
        previousState: previousState,
        previousSystemProxyEnabled: previousSystemProxyEnabled,
        generation: generation)
      return
    }

    guard generation == modeChangeGeneration else { return }
    let healthy = await presentLaunchHealth(
      document,
      requiresReceipt: true,
      convergeProxyOnSuccess: false,
      preserveProxyOnFailure: true)
    guard generation == modeChangeGeneration else { return }
    guard healthy else {
      await restoreModeTransition(
        previousMode: previousMode,
        previousDocument: previousDocument,
        previousState: previousState,
        previousSystemProxyEnabled: previousSystemProxyEnabled,
        generation: generation)
      return
    }

    lastDocument = document
    await convergeSystemProxy()
  }

  private func restoreModeTransition(
    previousMode: ProxyMode,
    previousDocument: SslocalRuntimeDocument,
    previousState: AgentRunState,
    previousSystemProxyEnabled: Bool,
    generation: Int
  ) async {
    var persistenceFailed = false
    var restoredSettings = settings
    restoredSettings.preferredMode = previousMode.kind
    do {
      try settingsStore.save(restoredSettings)
    } catch {
      persistenceFailed = true
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    }
    guard generation == modeChangeGeneration else { return }
    settings = restoredSettings
    proxyMode = previousMode
    lastDocument = previousDocument

    let expectedDigest = previousDocument.deploymentSHA256
    let currentDocument = runtimeFileStore.loadDocument()
    let receipt = runtimeFileStore.readRuntimeReceipt()
    let wrapper = wrapperState()
    let previousInstanceIsRunning: Bool
    switch wrapper {
    case .running(let pid):
      previousInstanceIsRunning =
        receipt?.processID == pid && receipt?.contractSHA256 == expectedDigest
    case .notRunning:
      previousInstanceIsRunning = false
    }
    if currentDocument != previousDocument || !previousInstanceIsRunning {
      do {
        if currentDocument != previousDocument {
          try runtimeFileStore.write(previousDocument)
        }
      } catch {
        state = .serviceFailed(.runtimeFile)
        await withdrawSystemProxyAfterEntryLoss()
        return
      }

      if !previousInstanceIsRunning {
        switch wrapper {
        case .running(let pid):
          guard sendSignal(pid, SIGUSR1) == 0 else {
            state = .serviceFailed(.agent)
            await withdrawSystemProxyAfterEntryLoss()
            return
          }
        case .notRunning:
          guard await execute(.run(previousDocument), document: previousDocument) else {
            guard generation == modeChangeGeneration else { return }
            await withdrawSystemProxyAfterEntryLoss()
            return
          }
        }
      }
    }

    guard generation == modeChangeGeneration else { return }
    state = .starting
    let restored = await presentLaunchHealth(
      previousDocument,
      requiresReceipt: true,
      convergeProxyOnSuccess: false)
    guard generation == modeChangeGeneration else { return }
    guard restored else {
      await withdrawSystemProxyAfterEntryLoss()
      return
    }

    if settings.systemProxyEnabled != previousSystemProxyEnabled {
      await convergeSystemProxy()
    } else {
      state = previousState
    }
    if persistenceFailed { state = .serviceFailed(.persistence) }
  }
}
