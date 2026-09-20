import Darwin
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

  static func unusedLoopbackPort() throws -> Int {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }
    defer { close(descriptor) }
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = 0
    address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
    let result = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard result == 0 else { throw POSIXError(.EADDRINUSE) }
    var bound = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &bound) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        getsockname(descriptor, $0, &length)
      }
    }
    guard nameResult == 0 else { throw POSIXError(.EINVAL) }
    return Int(CFSwapInt16BigToHost(bound.sin_port))
  }

  static func makeDocument(
    serverAddress: String = "203.0.113.7",
    password: String = "resolved-password",
    pluginOpts: String? = nil,
    localAddress: String = "127.0.0.1",
    localPort: Int = 1086,
    inboundProtocol: String = "socks",
    mode: String = "tcp_only",
    pacPort: Int = 1089
  ) -> SslocalRuntimeDocument {
    precondition(inboundProtocol == "socks")
    let scope: ListenScope =
      localAddress == "127.0.0.1"
      ? .loopback : .host(advertisedAddress: localAddress)
    return SslocalRuntimeDocument(
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
      listen: SslocalListenSettings(
        scope: scope,
        socksPort: localPort,
        httpProxyEnabled: false,
        httpPort: 1087,
        pacPort: pacPort,
        udpRelayEnabled: mode == "tcp_and_udp"))
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
  final class FakeProbe: EndpointProbing, @unchecked Sendable {
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

  final class FakePACProbe: PACHealthProbing, @unchecked Sendable {
    private let lock = NSLock()
    private let outcome: PACHealthOutcome
    private(set) var callCount = 0

    init(_ outcome: PACHealthOutcome = .reachable) {
      self.outcome = outcome
    }

    func probe(url: URL, timeout: TimeInterval) async -> PACHealthOutcome {
      lock.lock()
      callCount += 1
      lock.unlock()
      return outcome
    }
  }

  final class FakeFirewallChecker: FirewallStatusChecking, @unchecked Sendable {
    private let lock = NSLock()
    private var outcomes: [FirewallBlockStatus]
    private var recordedURLs: [URL] = []

    var checkedURLs: [URL] {
      lock.lock()
      defer { lock.unlock() }
      return recordedURLs
    }

    init(_ result: FirewallBlockStatus = .permitted) {
      outcomes = [result]
    }

    init(outcomes: [FirewallBlockStatus]) {
      precondition(!outcomes.isEmpty)
      self.outcomes = outcomes
    }

    func status(for executableURL: URL) -> FirewallBlockStatus {
      lock.lock()
      defer { lock.unlock() }
      recordedURLs.append(executableURL)
      let outcome = outcomes[0]
      if outcomes.count > 1 { outcomes.removeFirst() }
      return outcome
    }
  }
}
