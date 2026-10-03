import XCTest

@testable import ShadowsocksX_NG2

/// 系统代理观察机 interface 驱动测试（ADR-0022 策略机抽取后）：不经控制器
/// 夹具，直接以三条缝的替身驱动 cleanup-until-quiet 循环与操作互斥。
@MainActor
final class SystemProxyObserverTests: XCTestCase {
  func testCleanupRescansWhileNetworkKeepsChangingThenGoesQuiet() async throws {
    let proxy = ProxyRuntimeFixture.FakeSystemProxy()
    let monitor = ProxyRuntimeFixture.FakeSystemProxyNetworkChangeMonitor()
    let observer = makeObserver(
      proxy: proxy, monitor: monitor, cleanupSettleNanoseconds: 1_000_000)
    // 第一次 clear 期间到达的网络变化触发整轮重扫；随后安静，循环收敛。
    var emittedChange = false
    proxy.onClear = {
      guard !emittedChange else { return }
      emittedChange = true
      monitor.emit([.networkConfiguration, .proxyConfiguration])
    }

    let outcome = await observer.clearAndStopSystemProxyObservation()

    XCTAssertEqual(outcome, .idle)
    XCTAssertEqual(proxy.clearCount, 2, "清理期内的网络变化必须触发整轮重扫")
    XCTAssertTrue(emittedChange)
    XCTAssertEqual(monitor.startCount, 1)
    XCTAssertEqual(monitor.stopCount, 1)
    XCTAssertEqual(observer.systemProxyObservationMode, .stopped)
    XCTAssertEqual(observer.systemProxyState, .idle)
    XCTAssertFalse(observer.systemProxyInspection.isBusy)
  }

  func testConvergeWaitsForInFlightOperationInsteadOfSkipping() async throws {
    let proxy = ProxyRuntimeFixture.FakeSystemProxy()
    let observer = makeObserver(proxy: proxy, cleanupSettleNanoseconds: 1_000_000)
    observer.systemProxyInitialApplyPending = true
    // 拉长首次读服务的窗口，制造进行中的操作。
    proxy.beforeRead = { _ = try? await Task.sleep(nanoseconds: 30_000_000) }

    let first = Task { await observer.convergeSystemProxy(forceApply: true) }
    try await Task.sleep(nanoseconds: 10_000_000)
    await observer.convergeSystemProxy(forceApply: true)
    await first.value

    XCTAssertEqual(proxy.applied.count, 2, "并发收敛必须等操作收尾后执行而非被跳过")
  }

  private func makeObserver(
    proxy: ProxyRuntimeFixture.FakeSystemProxy,
    monitor: SystemProxyNetworkChangeMonitoring =
      ProxyRuntimeFixture.FakeSystemProxyNetworkChangeMonitor(),
    cleanupSettleNanoseconds: UInt64
  ) -> SystemProxyObserver {
    SystemProxyObserver(
      systemProxy: proxy,
      systemProxyHelper: ProxyRuntimeFixture.FakeSystemProxyHelperService(),
      systemProxyNetworkChangeMonitor: monitor,
      appBundle: AppArtifact.bundle,
      helperRefreshDelayNanoseconds: 1_000_000,
      cleanupSettleNanoseconds: cleanupSettleNanoseconds,
      isIntentEnabled: { true },
      isExitAvailable: { true },
      desiredConfiguration: {
        try? ProxyMode.direct.systemProxyConfiguration(
          for: SslocalRuntimeDocument(servers: [], listen: SslocalListenSettings()),
          exceptions: [])
      },
      startSystemProxyHealthObservation: {})
  }
}
