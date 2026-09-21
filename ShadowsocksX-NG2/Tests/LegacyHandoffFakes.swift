import Foundation
import XCTest

@testable import ShadowsocksX_NG2

// MARK: - 交接测试假实现（LegacyHandoffTests / LegacyHandoffViewModelTests 共用）

struct FixedPortsProvider: LegacyListenPortsProviding {
  func currentPorts() -> LegacyListenPorts { .factory() }
}

final class FakeHandoffMarker: LegacyHandoffMarkerStoring, @unchecked Sendable {
  var completed = false

  func isCompleted() -> Bool { completed }

  func setCompleted(_ completed: Bool) { self.completed = completed }
}

final class FakePlistInspector: LegacyAgentPlistInspecting, @unchecked Sendable {
  let residues: [LegacyAgentPlistResidue]

  init(residues: [LegacyAgentPlistResidue]) {
    self.residues = residues
  }

  func residue(for label: String) -> LegacyAgentPlistResidue {
    residues.first { $0.label == label }
      ?? LegacyAgentPlistResidue(
        label: label, fileExists: false, keepAlive: false, runAtLoad: false)
  }
}

final class FakeLegacyAppController: LegacyAppControlling, @unchecked Sendable {
  var running = false
  var installed = false
  private(set) var quitRequested = false

  func isRunning() -> Bool { running }

  func isInstalled() -> Bool { installed }

  func requestGracefulQuit() -> Bool {
    quitRequested = true
    running = false
    return true
  }
}

final class FakeOccupancyProbe: PortOccupancyProbing, @unchecked Sendable {
  var occupiers: [Int: String] = [:]
  /// 每个端口第 N 次起探测为空闲；nil 表示始终按 occupiers 判定。
  var occupanciesUntilFree: Int?
  private(set) var probedPorts: [Int] = []

  func occupancy(port: Int, bindAddress: String) -> PortOccupancy {
    probedPorts.append(port)
    if let untilFree = occupanciesUntilFree {
      let probes = probedPorts.filter { $0 == port }.count
      if probes >= untilFree { return .free }
    }
    guard let occupier = occupiers[port] else { return .free }
    return .occupied(occupier: occupier)
  }
}

final class FakeProxyCleaner: LegacyProxyCleaning, @unchecked Sendable {
  let outcome: LegacyProxyCleanOutcome?
  let error: LegacyHandoffError?
  private(set) var cleanCall: LegacyListenPorts?

  init(outcome: LegacyProxyCleanOutcome? = nil, error: LegacyHandoffError? = nil) {
    self.outcome = outcome
    self.error = error
  }

  func cleanLegacyOwnedProxy(ports: LegacyListenPorts) throws -> LegacyProxyCleanOutcome {
    cleanCall = ports
    if let error { throw error }
    return outcome ?? LegacyProxyCleanOutcome(cleanedServiceIDs: [], unknownOwnerServiceIDs: [])
  }
}

/// launchctl 假实现：维护按 label 的加载态机，记录全部调用。
final class FakeLaunchctl: LaunchctlControlling, @unchecked Sendable {
  enum LaunchctlCall: Equatable {
    case state(label: String)
    case bootout(label: String)
    case disable(label: String)
    case kill(label: String, signal: Int32)
  }

  enum BootoutBehavior {
    case removes
    case succeedsButKeepsLoaded
    case unremovable
    case alreadyGone
  }

  var loadedLabels: Set<String> = []
  var bootoutBehavior: [String: BootoutBehavior] = [:]
  var disableFailures: [String: LaunchctlOutcome] = [:]
  var printFailureDetail: [String: String] = [:]
  private(set) var recordedCalls: [LaunchctlCall] = []

  func serviceState(label: String) -> LaunchctlServiceState {
    recordedCalls.append(.state(label: label))
    if let detail = printFailureDetail[label] { return .unknown(detail: detail) }
    return loadedLabels.contains(label) ? .loaded : .notLoaded
  }

  func bootout(label: String) -> LaunchctlOutcome {
    recordedCalls.append(.bootout(label: label))
    switch bootoutBehavior[label] ?? .removes {
    case .removes:
      loadedLabels.remove(label)
      return LaunchctlOutcome(exitCode: 0, stderr: "")
    case .succeedsButKeepsLoaded:
      return LaunchctlOutcome(exitCode: 0, stderr: "")
    case .unremovable:
      return LaunchctlOutcome(exitCode: 1, stderr: "launchctl: Operation not permitted")
    case .alreadyGone:
      loadedLabels.remove(label)
      // 实弹验证：bootout 未加载 label 的退出码是 3，不是 print 的 113。
      return LaunchctlOutcome(exitCode: 3, stderr: "Boot-out failed: 3: No such process")
    }
  }

  func disable(label: String) -> LaunchctlOutcome {
    recordedCalls.append(.disable(label: label))
    if let failure = disableFailures[label] { return failure }
    return LaunchctlOutcome(exitCode: 0, stderr: "")
  }

  func kill(label: String, signal: Int32) -> LaunchctlOutcome {
    recordedCalls.append(.kill(label: label, signal: signal))
    if bootoutBehavior[label] == .unremovable { return LaunchctlOutcome(exitCode: 0, stderr: "") }
    loadedLabels.remove(label)
    return LaunchctlOutcome(exitCode: 0, stderr: "")
  }
}

extension LegacyListenPorts {
  /// 出厂三端口（D8：1086/1087/1089）。
  static func factory(
    socksPort: Int = 1086, httpPort: Int = 1087, pacPort: Int = 1089
  ) -> LegacyListenPorts {
    LegacyListenPorts(
      socksPort: socksPort, httpPort: httpPort, pacPort: pacPort, socksAddress: "127.0.0.1")
  }
}
