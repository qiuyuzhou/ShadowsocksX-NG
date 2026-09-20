import XCTest

@testable import ShadowsocksX_NG2

/// 代理运行时测试共享夹具（票 #27）：临时 v2 目录、契约文档构造、LaunchAgent
/// 与探测替身。
enum ProxyRuntimeFixture {
  /// 在临时目录中建一套隔离的运行时文件组（不触碰真实 ~/Library）。
  struct TemporaryV2 {
    let directory: URL
    let contract: URL
    let pidFile: URL
  }

  static func makeTemporaryV2(file: StaticString = #filePath, line: UInt = #line)
    -> TemporaryV2
  {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-tests-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return TemporaryV2(
      directory: directory,
      contract: directory.appendingPathComponent("sslocal-active.json"),
      pidFile: directory.appendingPathComponent("agent.pid"))
  }

  static func makeDocument(
    serverAddress: String = "203.0.113.7",
    password: String = "resolved-password",
    pluginOpts: String? = nil,
    localAddress: String = "127.0.0.1",
    localPort: Int = 1086,
    inboundProtocol: String = "socks",
    mode: String = "tcp_only"
  ) -> SslocalRuntimeDocument {
    SslocalRuntimeDocument(
      servers: [
        SslocalServerDocument(
          id: "server-1",
          remarks: "香港 01",
          server: serverAddress,
          serverPort: 8388,
          password: password,
          method: "aes-256-gcm",
          plugin: nil,
          pluginOpts: pluginOpts
        )
      ],
      localAddress: localAddress,
      localPort: localPort,
      inboundProtocol: inboundProtocol,
      mode: mode
    )
  }

  /// LaunchAgent 注册态可编程替身，记录全部调用。
  final class FakeLaunchAgent: LaunchAgentControlling {
    private(set) var currentStatus: LaunchAgentStatus
    private(set) var registerCount = 0
    private(set) var unregisterCount = 0
    var registerError: Error?
    /// register() 成功后自动迁移到的状态（模拟 launchd 拉起）。
    var statusAfterRegister: LaunchAgentStatus = .registered

    init(initialStatus: LaunchAgentStatus = .notRegistered) {
      currentStatus = initialStatus
    }

    var status: LaunchAgentStatus { currentStatus }

    func setStatus(_ status: LaunchAgentStatus) {
      currentStatus = status
    }

    func register() throws {
      registerCount += 1
      if let registerError {
        currentStatus = .registered
        throw registerError
      }
      currentStatus = statusAfterRegister
    }

    func unregister() throws {
      unregisterCount += 1
      currentStatus = .notRegistered
    }
  }

  /// 探测替身：按预设序列返回，序列耗尽后停留在最后一项。
  final class FakeProbe: EndpointProbing {
    private let lock = NSLock()
    private var outcomes: [EndpointHealthProbe.Outcome]
    private(set) var callCount = 0

    init(outcomes: [EndpointHealthProbe.Outcome]) {
      self.outcomes = outcomes
    }

    static func reachable() -> FakeProbe {
      FakeProbe(outcomes: [.reachable])
    }

    static func refusing() -> FakeProbe {
      FakeProbe(outcomes: [.refused(detail: "Connection refused")])
    }

    func probe(host: String, port: Int, timeout: TimeInterval) -> EndpointHealthProbe.Outcome {
      lock.lock()
      defer { lock.unlock() }
      callCount += 1
      guard let outcome = outcomes.first else { return .timedOut }
      if outcomes.count > 1 {
        outcomes.removeFirst()
      }
      return outcome
    }
  }
}
