import Foundation
import XCTest

@testable import ShadowsocksX_NG2

/// 轮询等待异步投影落定（设置工作流测试共享）。
func waitUntil(
  _ condition: @autoclosure () -> Bool,
  timeout: TimeInterval = 2,
  file: StaticString = #filePath,
  line: UInt = #line
) async {
  let deadline = Date().addingTimeInterval(timeout)
  while !condition() && Date() < deadline {
    try? await Task.sleep(nanoseconds: 10_000_000)
  }
  XCTAssertTrue(condition(), file: file, line: line)
}

/// 设置工作流测试的写入缝替身（issue #44）：记录提交与重置调用，可注入
/// 失败；不触碰真实偏好文件、钥匙串或运行时。
@MainActor
final class FakeSettingsCommitter: SettingsCommitting {
  var committedSettings: ProxySettings = ProxySettings()
  var isProxyRunning = false
  var updateError: Error?
  var resetError: Error?
  private(set) var updateCalls: [ProxySettings] = []
  private(set) var resetCallCount = 0

  func updateSettings(_ proposed: ProxySettings) async throws {
    if let updateError { throw updateError }
    updateCalls.append(proposed)
    committedSettings = proposed
  }

  func resetPreferences() async throws {
    if let resetError { throw resetError }
    resetCallCount += 1
    committedSettings = ProxySettings()
  }
}

/// 占用探测替身：按端口预设占用/不可判定，记录全部探测请求。
final class FakeOccupancyProbe: PortOccupancyProbing, @unchecked Sendable {
  private let lock = NSLock()
  private let occupiedPorts: Set<Int>
  private let unknownPorts: Set<Int>
  private var requestedPorts: [Int] = []
  private var answerOverride: PortOccupancy?

  init(occupiedPorts: Set<Int> = [], unknownPorts: Set<Int> = []) {
    self.occupiedPorts = occupiedPorts
    self.unknownPorts = unknownPorts
  }

  var requested: [Int] {
    lock.lock()
    defer { lock.unlock() }
    return requestedPorts
  }

  var callCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return requestedPorts.count
  }

  /// 覆盖全部端口的应答（占用代际测试用）。
  func setAnswer(_ answer: PortOccupancy?) {
    lock.lock()
    defer { lock.unlock() }
    answerOverride = answer
  }

  func occupancy(port: Int, bindAddress: String) -> PortOccupancy {
    lock.lock()
    defer { lock.unlock() }
    requestedPorts.append(port)
    if let answerOverride { return answerOverride }
    if unknownPorts.contains(port) {
      return .unknown(detail: "无法判定")
    }
    return occupiedPorts.contains(port) ? .occupied(occupier: "other-app") : .free
  }
}

/// 分阶段占用探测替身（占用代际测试用）：门闩阶段的调用先记下自己的应答再
/// 被扣住，`passThrough` 之后的调用立即返回新应答。用于把「旧一轮」结果钉在
/// 新一轮之后落盘，验证过期结果不得覆盖。
final class GatedOccupancyProbe: PortOccupancyProbing, @unchecked Sendable {
  private let lock = NSLock()
  private let gate = DispatchGroup()
  private var isGated = true
  private var enteredCount = 0
  private var gatedAnswer: PortOccupancy
  private var passThroughAnswer: PortOccupancy

  init(gatedAnswer: PortOccupancy, passThroughAnswer: PortOccupancy) {
    self.gatedAnswer = gatedAnswer
    self.passThroughAnswer = passThroughAnswer
    gate.enter()
  }

  /// 已进入探测的调用数（按端口标识序，socks 先于 http/pac）。
  var entered: Int {
    lock.lock()
    defer { lock.unlock() }
    return enteredCount
  }

  /// 之后的调用立即返回 `answer`；已进入且被扣住的调用仍持有各自应答。
  func passThrough(_ answer: PortOccupancy) {
    lock.lock()
    defer { lock.unlock() }
    isGated = false
    passThroughAnswer = answer
  }

  /// 放行全部被扣住的调用（广播门闩）。
  func releaseGatedCalls() {
    lock.lock()
    let wasGated = isGated
    isGated = false
    lock.unlock()
    if wasGated {
      gate.leave()
    }
  }

  func occupancy(port: Int, bindAddress: String) -> PortOccupancy {
    lock.lock()
    enteredCount += 1
    let gated = isGated
    let answer = gated ? gatedAnswer : passThroughAnswer
    lock.unlock()
    if gated {
      gate.wait()
    }
    return answer
  }
}
