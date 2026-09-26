import Foundation

private struct LocalEndpointFailure {
  let local: SslocalLocalDocument
  let host: String
  let outcome: EndpointHealthProbe.Outcome
}

private enum LaunchHealthAttempt {
  case ready(RuntimeDeploymentReceipt?)
  case retry(LocalEndpointFailure?)
  case agentLost
}

private struct LaunchHealthTimeout {
  let expectedDigest: String?
  let endpointFailure: LocalEndpointFailure?
  let generation: Int
  let preserveProxyOnFailure: Bool
}

extension ProxyRuntimeController {
  /// 启动健康呈现（D2/D7/D8）：确认本地入站；直连模式额外要求
  /// 回执持续指向当前健康子进程，防止旧监听通过共享端口冒充新实例。
  @discardableResult
  func presentLaunchHealth(
    _ document: SslocalRuntimeDocument,
    requiresReceipt: Bool = false,
    convergeProxyOnSuccess: Bool = true,
    preserveProxyOnFailure: Bool = false
  ) async -> Bool {
    let generation = flowGeneration
    let expectedDigest = requiresReceipt ? document.deploymentSHA256 : nil
    guard !requiresReceipt || expectedDigest != nil else {
      return await reportRuntimeFileFailure(preserveProxyOnFailure: preserveProxyOnFailure)
    }

    let deadline = Date().addingTimeInterval(launchHealthTimeoutSeconds)
    var endpointFailure: LocalEndpointFailure?
    while Date() < deadline {
      guard generation == flowGeneration else { return false }
      switch await launchHealthAttempt(document, expectedDigest: expectedDigest) {
      case .ready(let receipt):
        return await finishHealthyLaunch(
          document,
          receipt: receipt,
          generation: generation,
          convergeProxyOnSuccess: convergeProxyOnSuccess,
          preserveProxyOnFailure: preserveProxyOnFailure)
      case .retry(let endpoint):
        endpointFailure = endpoint
      case .agentLost:
        return await reportAgentLost(preserveProxyOnFailure: preserveProxyOnFailure)
      }
      try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return await reportLaunchHealthTimeout(
      LaunchHealthTimeout(
        expectedDigest: expectedDigest,
        endpointFailure: endpointFailure,
        generation: generation,
        preserveProxyOnFailure: preserveProxyOnFailure))
  }

  private func launchHealthAttempt(
    _ document: SslocalRuntimeDocument,
    expectedDigest: String?
  ) async -> LaunchHealthAttempt {
    var receiptForHealth: RuntimeDeploymentReceipt?
    if let expectedDigest {
      guard let receipt = runtimeFileStore.readRuntimeReceipt(),
        receipt.contractSHA256 == expectedDigest
      else {
        return .retry(nil)
      }
      guard receipt.processID > 0, processIsAlive(receipt.processID) else {
        return .agentLost
      }
      receiptForHealth = receipt
    }

    if let endpointFailure = await unhealthyLocalEndpoint(in: document) {
      return .retry(endpointFailure)
    }

    if let receiptForHealth {
      guard runtimeFileStore.readRuntimeReceipt() == receiptForHealth else {
        return .retry(nil)
      }
      guard processIsAlive(receiptForHealth.processID) else { return .agentLost }
    }
    return .ready(receiptForHealth)
  }

  private func finishHealthyLaunch(
    _ document: SslocalRuntimeDocument,
    receipt: RuntimeDeploymentReceipt?,
    generation: Int,
    convergeProxyOnSuccess: Bool,
    preserveProxyOnFailure: Bool
  ) async -> Bool {
    guard generation == flowGeneration else { return false }
    await presentFirewallStatus(for: document)
    if let receipt, !receiptIsCurrentAndLive(receipt) {
      return await reportAgentLost(preserveProxyOnFailure: preserveProxyOnFailure)
    }
    if convergeProxyOnSuccess { await convergeSystemProxy() }
    return true
  }

  private func receiptIsCurrentAndLive(_ receipt: RuntimeDeploymentReceipt) -> Bool {
    guard receipt.processID > 0,
      runtimeFileStore.readRuntimeReceipt() == receipt
    else { return false }
    return processIsAlive(receipt.processID)
  }

  private func reportAgentLost(preserveProxyOnFailure: Bool) async -> Bool {
    guard !preserveProxyOnFailure else { return false }
    state = .serviceFailed(.agent)
    await withdrawSystemProxyAfterEntryLoss()
    return false
  }

  private func reportRuntimeFileFailure(preserveProxyOnFailure: Bool) async -> Bool {
    guard !preserveProxyOnFailure else { return false }
    state = .serviceFailed(.runtimeFile)
    await withdrawSystemProxyAfterEntryLoss()
    return false
  }

  private func reportLaunchHealthTimeout(_ timeout: LaunchHealthTimeout) async -> Bool {
    guard timeout.generation == flowGeneration else { return false }
    guard !timeout.preserveProxyOnFailure else { return false }
    if let expectedDigest = timeout.expectedDigest,
      !hasLiveReceipt(expectedDigest: expectedDigest)
    {
      return await reportAgentLost(preserveProxyOnFailure: false)
    }
    if let endpointFailure = timeout.endpointFailure {
      presentEndpointFailure(endpointFailure)
    } else {
      state = .launchFailed(
        .localEndpoint(endpoint: "SOCKS", host: "127.0.0.1", port: 0, cause: .unknown))
    }
    await withdrawSystemProxyAfterEntryLoss()
    return false
  }

  private func hasLiveReceipt(expectedDigest: String) -> Bool {
    guard let receipt = runtimeFileStore.readRuntimeReceipt(),
      receipt.contractSHA256 == expectedDigest
    else { return false }
    return receiptIsCurrentAndLive(receipt)
  }

  private func unhealthyLocalEndpoint(
    in document: SslocalRuntimeDocument
  ) async -> LocalEndpointFailure? {
    for local in document.locals {
      let outcome = await probeAsync(
        host: local.probeHost, port: local.localPort, timeout: 1.5)
      if outcome != .reachable {
        return LocalEndpointFailure(local: local, host: local.probeHost, outcome: outcome)
      }
    }
    return nil
  }

  private func presentEndpointFailure(_ failure: LocalEndpointFailure) {
    let detail: String
    let cause: RuntimeEndpointFailure
    switch failure.outcome {
    case .reachable:
      detail = "已连通"
      cause = .unknown
    case .refused(let reason):
      detail = reason
      cause = .refused
    case .timedOut:
      detail = "连接超时"
      cause = .timedOut
    }
    RuntimeLog.emit(
      .endpointProbeFailed(
        host: failure.host, port: failure.local.localPort, detail: detail))
    let endpointName = failure.local.inboundProtocol.uppercased()
    state = .launchFailed(
      .localEndpoint(
        endpoint: endpointName, host: failure.host, port: failure.local.localPort, cause: cause))
  }
}
