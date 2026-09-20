import XCTest

@testable import ShadowsocksX_NG2

/// 薄 I/O 缝 ②（spec #21 Testing Decisions）：以 stub sslocal 二进制驱动真实
/// wrapper 可执行文件，验证启停协议次序、SIGTERM 链、崩溃恢复、文件清理与
/// SIGUSR1 变更协议（D2/D5）。stub 经环境变量编排行为，全部等待有界。
final class AgentLifecycleTests: XCTestCase {
  private var workDir: URL!
  private var contractURL: URL!
  private var stubStateURL: URL!
  private var stubURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-agent-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    contractURL = workDir.appendingPathComponent("sslocal-active.json")
    stubStateURL = workDir.appendingPathComponent("stub-state.log")
    stubURL = workDir.appendingPathComponent("stub-sslocal.sh")
    try writeStubScript()
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: workDir)
    try super.tearDownWithError()
  }

  // MARK: 夹具

  private var wrapperURL: URL {
    get throws {
      let url = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/ShadowsocksX-NG2Agent")
      return try XCTUnwrap(
        FileManager.default.fileExists(atPath: url.path) ? url : nil,
        "wrapper 未嵌入 app bundle（Contents/MacOS/ShadowsocksX-NG2Agent）")
    }
  }

  private func writeStubScript() throws {
    // stub 记录调用参数与收到的信号；行为由 SSLOCAL_STUB_BEHAVIOR 编排。
    let script = """
      #!/bin/sh
      echo "invoked: $*" >> "$SSLOCAL_STUB_STATE"
      trap 'echo "SIGTERM" >> "$SSLOCAL_STUB_STATE"; exit 0' TERM
      trap 'echo "SIGUSR1" >> "$SSLOCAL_STUB_STATE"' USR1
      case "$SSLOCAL_STUB_BEHAVIOR" in
        crash) exit 7 ;;
        exit0) exit 0 ;;
        *) while :; do sleep 0.05; done ;;
      esac
      """
    try script.write(to: stubURL, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes(
      [.posixPermissions: 0o755], ofItemAtPath: stubURL.path)
  }

  private func launchWrapper(behavior: String) throws -> Process {
    let wrapper = try wrapperURL
    let process = Process()
    process.executableURL = wrapper
    var environment = ProcessInfo.processInfo.environment
    environment["SSXNG_CONTRACT_PATH"] = contractURL.path
    environment["SSXNG_SSLOCAL_PATH"] = stubURL.path
    environment["SSXNG_V2_DIR"] = workDir.path
    environment["SSLOCAL_STUB_STATE"] = stubStateURL.path
    environment["SSLOCAL_STUB_BEHAVIOR"] = behavior
    process.environment = environment
    try process.run()
    return process
  }

  private func writeContract(_ document: SslocalRuntimeDocument) throws {
    try document.jsonData().write(to: contractURL)
  }

  private func stateLog() -> String {
    (try? String(contentsOf: stubStateURL, encoding: .utf8)) ?? ""
  }

  private func pidAlive(_ pid: Int32) -> Bool {
    kill(pid, 0) == 0
  }

  @discardableResult
  private func waitUntil(
    timeout: TimeInterval = 10, _ condition: () throws -> Bool
  ) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if try condition() { return true }
      Thread.sleep(forTimeInterval: 0.05)
    }
    return try condition()
  }

  /// 断言 wrapper 在超时内退出并返回退出码。
  private func waitForExit(_ process: Process, timeout: TimeInterval = 10) throws -> Int32 {
    try waitUntil(timeout: timeout) { !process.isRunning }
    process.waitUntilExit()
    return process.terminationStatus
  }

  // MARK: 启动协议与 SIGTERM 链（D2）

  func testStartProtocolSpawnsSslocalWithAbsoluteConfigPathThenStopsOnSIGTERM() throws {
    try writeContract(ProxyRuntimeFixture.makeDocument())
    let wrapper = try launchWrapper(behavior: "run")

    XCTAssertTrue(
      try waitUntil { self.stateLog().contains("invoked: -c \(self.contractURL.path)") },
      "wrapper 应以契约绝对路径调用 sslocal，实际：\(stateLog())")
    XCTAssertTrue(pidAlive(wrapper.processIdentifier), "sslocal 运行期间 wrapper 应保持常驻")

    kill(wrapper.processIdentifier, SIGTERM)
    let exitStatus = try waitForExit(wrapper)

    XCTAssertEqual(exitStatus, 0, "显式停止后 wrapper 干净退出（不触发 KeepAlive 重启）")
    XCTAssertTrue(stateLog().contains("SIGTERM"), "SIGTERM 链：wrapper 转发给 sslocal")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: contractURL.path),
      "停止路径不动契约文件（删除由 GUI 的停止协议末端负责）")
  }

  func testPACEndpointLivesAndDiesWithWrapper() throws {
    let pacPort = try ProxyRuntimeFixture.unusedLoopbackPort()
    try writeContract(ProxyRuntimeFixture.makeDocument(localPort: 2086, pacPort: pacPort))
    let wrapper = try launchWrapper(behavior: "run")

    XCTAssertTrue(
      try waitUntil {
        EndpointHealthProbe.probe(host: "127.0.0.1", port: pacPort, timeout: 0.2)
          == .reachable
      },
      "wrapper 运行期间 PAC endpoint 应可达")
    let response = try loadPAC(port: pacPort)
    XCTAssertEqual(response.statusCode, 200)
    XCTAssertEqual(response.mimeType, "application/x-ns-proxy-autoconfig")
    XCTAssertTrue(
      response.body.contains("SOCKS5 127.0.0.1:2086"),
      "PAC 内容必须指向同一运行时文档派生的 SOCKS 入站")

    kill(wrapper.processIdentifier, SIGTERM)
    XCTAssertEqual(try waitForExit(wrapper), 0)
    XCTAssertNotEqual(
      EndpointHealthProbe.probe(host: "127.0.0.1", port: pacPort, timeout: 0.2),
      .reachable,
      "wrapper 停止后 PAC endpoint 必须不可达")
  }

  // MARK: 崩溃恢复（D2）

  func testSslocalCrashExitsNonZeroForKeepAliveReplay() throws {
    try writeContract(ProxyRuntimeFixture.makeDocument())
    let wrapper = try launchWrapper(behavior: "crash")

    let exitStatus = try waitForExit(wrapper)

    XCTAssertNotEqual(exitStatus, 0, "sslocal 崩溃 → wrapper 非零退出 → KeepAlive 重启重放")

    // KeepAlive 重放语义：同一份契约再拉起一次即恢复（stub 换回常驻行为）。
    let replay = try launchWrapper(behavior: "run")
    XCTAssertTrue(
      try waitUntil { self.stateLog().components(separatedBy: "invoked:").count >= 3 },
      "重放应再次拉起 sslocal")
    kill(replay.processIdentifier, SIGTERM)
    XCTAssertEqual(try waitForExit(replay), 0)
  }

  func testUnexpectedCleanChildExitAlsoCountsAsLoss() throws {
    try writeContract(ProxyRuntimeFixture.makeDocument())
    let wrapper = try launchWrapper(behavior: "exit0")

    let exitStatus = try waitForExit(wrapper)

    XCTAssertNotEqual(
      exitStatus, 0, "sslocal 自行退出（即使干净）也应触发重放而非静默下线")
  }

  // MARK: 契约缺失 / 无效 → 停止并清理（D5）

  func testMissingContractExitsCleanlyWithoutSpawning() throws {
    let wrapper = try launchWrapper(behavior: "run")

    let exitStatus = try waitForExit(wrapper)

    XCTAssertEqual(exitStatus, 0, "无契约干净退出，KeepAlive（SuccessfulExit:false）不重启")
    XCTAssertFalse(stateLog().contains("invoked"), "不应拉起 sslocal")
  }

  func testInvalidContractIsUnlinkedThenCleanExit() throws {
    try Data("not valid json {".utf8).write(to: contractURL)
    let wrapper = try launchWrapper(behavior: "run")

    let exitStatus = try waitForExit(wrapper)

    XCTAssertEqual(exitStatus, 0)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: contractURL.path),
      "无效契约按「停止并清理」普通 unlink（D5）")
    XCTAssertFalse(stateLog().contains("invoked"))
  }

  func testStructurallyInvalidContractIsAlsoCleaned() throws {
    // 可解码但 servers 为空：wrapper 校验拒绝，不给 sslocal 反复失败的机会。
    try SslocalRuntimeDocument(
      servers: [], listen: SslocalListenSettings(httpProxyEnabled: false)
    ).jsonData().write(to: contractURL)
    let wrapper = try launchWrapper(behavior: "run")

    let exitStatus = try waitForExit(wrapper)

    XCTAssertEqual(exitStatus, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: contractURL.path))
  }

  // MARK: 变更协议（D5）

  func testSIGUSR1WithServerOnlyChangeIsForwardedToSslocal() throws {
    try writeContract(ProxyRuntimeFixture.makeDocument(serverAddress: "203.0.113.7"))
    let wrapper = try launchWrapper(behavior: "run")
    XCTAssertTrue(
      try waitUntil { self.stateLog().contains("invoked:") }, "等待首次拉起")

    try writeContract(ProxyRuntimeFixture.makeDocument(serverAddress: "198.51.100.9"))
    kill(wrapper.processIdentifier, SIGUSR1)

    XCTAssertTrue(
      try waitUntil { self.stateLog().contains("SIGUSR1") },
      "仅服务器列表变化应转发 SIGUSR1 热重载（上游只替换配置来源服务器）")
    XCTAssertTrue(pidAlive(wrapper.processIdentifier), "热重载不重启 wrapper")
    XCTAssertFalse(stateLog().contains("SIGTERM"), "热重载不触发子进程重启")

    kill(wrapper.processIdentifier, SIGTERM)
    XCTAssertEqual(try waitForExit(wrapper), 0)
  }

  func testSIGUSR1WithListenChangePerformsGracefulRestart() throws {
    try writeContract(ProxyRuntimeFixture.makeDocument(localPort: 1086))
    let wrapper = try launchWrapper(behavior: "run")
    XCTAssertTrue(
      try waitUntil { self.stateLog().contains("invoked:") }, "等待首次拉起")

    try writeContract(ProxyRuntimeFixture.makeDocument(localPort: 2086))
    kill(wrapper.processIdentifier, SIGUSR1)

    XCTAssertTrue(
      try waitUntil {
        self.stateLog().contains("SIGTERM")
          && self.stateLog().components(separatedBy: "invoked:").count >= 3
      },
      "监听结构变化走优雅重启：先 SIGTERM 旧实例再以新契约拉起，实际：\(stateLog())")
    XCTAssertTrue(pidAlive(wrapper.processIdentifier), "重启后 wrapper 常驻")

    // 重启后的实例也要能被显式停止。
    kill(wrapper.processIdentifier, SIGTERM)
    XCTAssertEqual(try waitForExit(wrapper), 0)
    XCTAssertEqual(
      stateLog().components(separatedBy: "SIGTERM").count - 1, 2,
      "两次停止各转发一次 SIGTERM")
  }

  // MARK: pid 文件契约

  func testWrapperWritesAndRemovesPIDFile() throws {
    let pidURL = workDir.appendingPathComponent("agent.pid")
    try writeContract(ProxyRuntimeFixture.makeDocument())
    let wrapper = try launchWrapper(behavior: "run")

    XCTAssertTrue(
      try waitUntil { FileManager.default.fileExists(atPath: pidURL.path) },
      "wrapper 启动即写 pid 文件（GUI 判活与 SIGUSR1 投递依据）")
    let recordedPID = Int32(
      String(data: try Data(contentsOf: pidURL), encoding: .utf8)?.trimmingCharacters(
        in: .whitespacesAndNewlines
      ) ?? "")
    XCTAssertEqual(recordedPID, wrapper.processIdentifier, "pid 文件记录 wrapper 自身 pid")

    kill(wrapper.processIdentifier, SIGTERM)
    _ = try waitForExit(wrapper)
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: pidURL.path), "退出路径清理 pid 文件")
  }

  private struct LoadedPAC {
    let statusCode: Int
    let mimeType: String?
    let body: String
  }

  private func loadPAC(port: Int) throws -> LoadedPAC {
    let finished = expectation(description: "PAC GET")
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 2
    let session = URLSession(configuration: configuration)
    var captured: Result<LoadedPAC, Error>?
    let pacURL = URL(string: "http://127.0.0.1:\(port)/v1/proxy.pac")!
    session.dataTask(with: pacURL) { data, response, error in
      defer { finished.fulfill() }
      if let error {
        captured = .failure(error)
        return
      }
      guard let http = response as? HTTPURLResponse, let data,
        let body = String(data: data, encoding: .utf8)
      else {
        captured = .failure(URLError(.badServerResponse))
        return
      }
      captured = .success(
        LoadedPAC(statusCode: http.statusCode, mimeType: http.mimeType, body: body))
    }.resume()
    wait(for: [finished], timeout: 3)
    session.invalidateAndCancel()
    return try XCTUnwrap(captured).get()
  }
}
