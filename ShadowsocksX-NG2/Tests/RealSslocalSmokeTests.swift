import Darwin
import XCTest

@testable import ShadowsocksX_NG2

/// 真实 sslocal 冒烟（issue #27 验收）：wrapper 驱动 bundle 内官方 sslocal
/// v1.25.0——本地 SOCKS 端口完成监听绑定，并完成一次完整 SOCKS5 握手（方法
/// 协商 + CONNECT 请求得到按协议的应答）。远端服务器不可达只影响应答码，不
/// 影响握手本身（真实服务器功能验证属发布门槛人工检查项）。
final class RealSslocalSmokeTests: XCTestCase {
  private var workDir: URL!
  private var contractURL: URL!

  override func setUpWithError() throws {
    try super.setUpWithError()
    workDir = FileManager.default.temporaryDirectory
      .appendingPathComponent("ssxng-smoke-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    contractURL = workDir.appendingPathComponent("sslocal-active.json")
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: workDir)
    try super.tearDownWithError()
  }

  private var sslocalURL: URL {
    get throws {
      let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/sslocal")
      return try XCTUnwrap(
        FileManager.default.fileExists(atPath: url.path) ? url : nil,
        "sslocal 未嵌入 app bundle（先跑 fetch-external-binaries.sh）")
    }
  }

  /// 绑定回环临时端口拿到空闲端口号后释放。
  private func grabEphemeralLoopbackPort() throws -> Int {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { throw POSIXError(.ENOTSOCK) }
    defer { close(socketFD) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_port = 0
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    XCTAssertEqual(bindResult, 0)
    XCTAssertEqual(listen(socketFD, 1), 0)

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(socketFD, sockaddrPointer, &length)
      }
    }
    XCTAssertEqual(nameResult, 0)
    return Int(CFSwapInt16BigToHost(boundAddress.sin_port))
  }

  /// 写入给定契约并拉起 wrapper（契约内容由调用方构造：无插件与插件场景各异）。
  private func launchWrapper(_ document: SslocalRuntimeDocument) throws -> Process {
    try RuntimeFileStore(fileURL: contractURL).write(document)

    let wrapperURL = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/MacOS/ShadowsocksX-NG2Agent")
    let process = Process()
    process.executableURL = wrapperURL
    var environment = ProcessInfo.processInfo.environment
    environment["SSXNG_CONTRACT_PATH"] = contractURL.path
    environment["SSXNG_SSLOCAL_PATH"] = try sslocalURL.path
    environment["SSXNG_RUNTIME_DIR"] = workDir.path
    process.environment = environment
    try process.run()
    return process
  }

  /// 对本地 SOCKS 端口做完整握手，返回 CONNECT 应答首字节（版本, 应答码）。
  private func performSocksHandshake(port: Int) throws -> (version: UInt8, reply: UInt8)? {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { throw POSIXError(.ENOTSOCK) }
    defer { close(socketFD) }

    var address = sockaddr_in()
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_port = in_port_t(port).bigEndian
    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connectResult == 0 else { return nil }

    // 方法协商：X'05' X'01' X'00'（一个无需认证的方法）。
    let greeting: [UInt8] = [0x05, 0x01, 0x00]
    XCTAssertEqual(try greeting.withUnsafeBytes { try writeAll(socketFD, $0) }, greeting.count)
    let methodReply = try readExactly(socketFD, count: 2)
    XCTAssertEqual(
      methodReply, [0x05, 0x00], "sslocal 应选定 NO-AUTH 方法", file: #filePath, line: #line)

    // CONNECT 127.0.0.1:1。
    let request: [UInt8] = [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1, 0x00, 0x01]
    _ = try request.withUnsafeBytes { try writeAll(socketFD, $0) }
    let replyHead = try readExactly(socketFD, count: 4)
    return (replyHead[0], replyHead[1])
  }

  private func writeAll(_ descriptor: Int32, _ buffer: UnsafeRawBufferPointer) throws -> Int {
    var total = 0
    while total < buffer.count {
      let written = write(descriptor, buffer.baseAddress!.advanced(by: total), buffer.count - total)
      guard written > 0 else { throw NSError(domain: "smoke", code: 1) }
      total += written
    }
    return total
  }

  private func readExactly(_ descriptor: Int32, count: Int) throws -> [UInt8] {
    var bytes: [UInt8] = []
    bytes.reserveCapacity(count)
    while bytes.count < count {
      var scratch: [UInt8] = Array(repeating: 0, count: count - bytes.count)
      let received = read(descriptor, &scratch, scratch.count)
      guard received > 0 else { throw NSError(domain: "smoke", code: 2) }
      bytes.append(contentsOf: scratch[0..<received])
    }
    return bytes
  }

  func testRealSslocalBindsSOCKSAndHTTPPortsAndCompletesHandshake() throws {
    var ports = Set<Int>()
    while ports.count < 3 {
      ports.insert(try grabEphemeralLoopbackPort())
    }
    let selectedPorts = Array(ports)
    let socksPort = selectedPorts[0]
    let httpPort = selectedPorts[1]
    let pacPort = selectedPorts[2]
    let document = SslocalRuntimeDocument(
      servers: [
        SslocalServerDocument(
          id: "smoke-server",
          remarks: "smoke",
          server: "127.0.0.1",
          serverPort: 1,  // 远端必然拒绝：只验证本地握手与 SSLOCAL 配置格式
          password: "smoke-password",
          method: "aes-256-gcm",
          plugin: nil,
          pluginOpts: nil)
      ],
      listen: SslocalListenSettings(
        socksPort: socksPort, httpPort: httpPort, pacPort: pacPort))
    let wrapper = try launchWrapper(document)

    // 两个端口同时就绪：验证 locals[] 被官方 sslocal 接受并实际绑定。
    var socksReachable = false
    var httpReachable = false
    let deadline = Date().addingTimeInterval(15)
    while (!socksReachable || !httpReachable) && Date() < deadline {
      socksReachable =
        EndpointHealthProbe.probe(host: "127.0.0.1", port: socksPort, timeout: 1) == .reachable
      httpReachable =
        EndpointHealthProbe.probe(host: "127.0.0.1", port: httpPort, timeout: 1) == .reachable
      if !socksReachable || !httpReachable {
        Thread.sleep(forTimeInterval: 0.2)
      }
    }
    XCTAssertTrue(socksReachable, "15 秒内本地 SOCKS 端口应完成监听绑定")
    XCTAssertTrue(httpReachable, "15 秒内本地 HTTP 端口应完成监听绑定")

    // 完整 SOCKS5 握手。
    let handshake = try performSocksHandshake(port: socksPort)
    let reply = try XCTUnwrap(handshake, "连接成功建立后应能完成握手")
    XCTAssertEqual(reply.version, 0x05, "应答版本应为 SOCKS5")
    // 远端不可达允许失败应答码；关键在于 sslocal 按协议给出 CONNECT 应答。

    // 显式停止：SIGTERM 链对真实 sslocal 同样成立。
    kill(wrapper.processIdentifier, SIGTERM)
    let exited = XCTestExpectation(description: "wrapper exits")
    DispatchQueue.global().async {
      wrapper.waitUntilExit()
      exited.fulfill()
    }
    XCTAssertEqual(
      XCTWaiter.wait(for: [exited], timeout: 10), .completed, "wrapper 应在 SIGTERM 后退出")
    XCTAssertEqual(wrapper.terminationStatus, 0, "显式停止干净退出")
  }

  /// 无活动服务器监听（issue #60）：空 `servers` 契约是合法部署——上游
  /// sslocal v1.25.0 接受空服务器列表并照常绑定 SOCKS/HTTP 入站；wrapper
  /// 的 PAC endpoint 同样照常服务。真实运行时证据（系统代理写入属真实宿主
  /// 验收，不在替身/回环测试范围内）。
  func testRealSslocalBindsLocalsWithEmptyServerList() throws {
    var ports = Set<Int>()
    while ports.count < 3 {
      ports.insert(try grabEphemeralLoopbackPort())
    }
    let selectedPorts = Array(ports)
    let document = SslocalRuntimeDocument(
      servers: [],
      listen: SslocalListenSettings(
        socksPort: selectedPorts[0], httpPort: selectedPorts[1], pacPort: selectedPorts[2]))
    XCTAssertTrue(document.isWellFormed, "空服务器列表契约有效")
    let wrapper = try launchWrapper(document)

    XCTAssertTrue(
      try waitForCondition(timeout: 15) {
        EndpointHealthProbe.probe(host: "127.0.0.1", port: selectedPorts[0], timeout: 1)
          == .reachable
      },
      "空服务器列表下本地 SOCKS 端口应完成监听绑定")
    XCTAssertTrue(
      try waitForCondition(timeout: 15) {
        EndpointHealthProbe.probe(host: "127.0.0.1", port: selectedPorts[1], timeout: 1)
          == .reachable
      },
      "空服务器列表下本地 HTTP 端口应完成监听绑定")
    XCTAssertTrue(
      try waitForCondition(timeout: 15) {
        EndpointHealthProbe.probe(host: "127.0.0.1", port: selectedPorts[2], timeout: 1)
          == .reachable
      },
      "空服务器列表下 PAC endpoint 应照常服务")

    kill(wrapper.processIdentifier, SIGTERM)
    let exited = XCTestExpectation(description: "wrapper exits")
    DispatchQueue.global().async {
      wrapper.waitUntilExit()
      exited.fulfill()
    }
    XCTAssertEqual(
      XCTWaiter.wait(for: [exited], timeout: 10), .completed, "wrapper 应在 SIGTERM 后退出")
    XCTAssertEqual(wrapper.terminationStatus, 0, "空监听会话的显式停止同样干净退出")
  }

  // MARK: - 受管插件端到端（issue #38）

  /// v2ray-plugin v1.3.2 端到端边界：契约携带 bundle 内插件绝对路径 → sslocal
  /// 拉起 → SIP003 插件进程建立 → 停止链随 sslocal 一并退出。插件进程退出会
  /// 连带 sslocal 退出（D10 以 sslocal 信号为准）；真实服务器数据面验证属发布
  /// 门槛人工项（spec #21 Further Notes #6），在此以进程边界验证。
  func testRealSslocalLaunchesManagedV2rayPluginProcess() throws {
    let pluginURL = Bundle.main.bundleURL.appendingPathComponent(
      "Contents/Helpers/Plugins/v2ray-plugin")
    _ = try XCTUnwrap(
      FileManager.default.isExecutableFile(atPath: pluginURL.path) ? pluginURL : nil,
      "v2ray-plugin 未嵌入 app bundle（先跑 fetch-external-binaries.sh）")
    var ports = Set<Int>()
    while ports.count < 3 {
      ports.insert(try grabEphemeralLoopbackPort())
    }
    let selectedPorts = Array(ports)
    let socksPort = selectedPorts[0]
    let httpPort = selectedPorts[1]
    let pacPort = selectedPorts[2]
    let document = SslocalRuntimeDocument(
      servers: [
        SslocalServerDocument(
          id: "smoke-plugin-server",
          remarks: "smoke-plugin",
          server: "127.0.0.1",
          serverPort: 1,  // 远端必然拒绝：只验证本地链路与插件进程边界
          password: "smoke-password",
          method: "aes-256-gcm",
          plugin: pluginURL.path,
          pluginOpts: "mode=websocket")
      ],
      listen: SslocalListenSettings(
        socksPort: socksPort, httpPort: httpPort, pacPort: pacPort))
    let wrapper = try launchWrapper(document)

    // 插件进程建立：sslocal 按 SIP003 拉起 bundle 内 v2ray-plugin 并保持运行
    // （sslocal 先等插件就绪再绑定本地监听，进程先于端口出现）。
    XCTAssertTrue(
      try waitForCondition(timeout: 15) { self.pluginProcessExists(path: pluginURL.path) },
      "sslocal 应拉起 bundle 内 v2ray-plugin 进程")

    XCTAssertTrue(
      try waitForCondition(timeout: 15) {
        EndpointHealthProbe.probe(host: "127.0.0.1", port: socksPort, timeout: 1) == .reachable
      },
      "15 秒内本地 SOCKS 端口应完成监听绑定")

    kill(wrapper.processIdentifier, SIGTERM)
    let exited = XCTestExpectation(description: "wrapper exits")
    DispatchQueue.global().async {
      wrapper.waitUntilExit()
      exited.fulfill()
    }
    XCTAssertEqual(
      XCTWaiter.wait(for: [exited], timeout: 10), .completed, "wrapper 应在 SIGTERM 后退出")
    XCTAssertEqual(wrapper.terminationStatus, 0)
    XCTAssertTrue(
      try waitForCondition(timeout: 8) { !self.pluginProcessExists(path: pluginURL.path) },
      "停止链应连带结束插件进程")
  }

  private func waitForCondition(
    timeout: TimeInterval, _ condition: () throws -> Bool
  ) throws -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      if try condition() { return true }
      Thread.sleep(forTimeInterval: 0.1)
    }
    return try condition()
  }

  /// 按完整可执行路径检索进程（pgrep 全命令行匹配）。
  private func pluginProcessExists(path: String) -> Bool {
    let pgrep = Process()
    pgrep.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    pgrep.arguments = ["-f", path]
    let pipe = Pipe()
    pgrep.standardOutput = pipe
    pgrep.standardError = FileHandle.nullDevice
    do {
      try pgrep.run()
    } catch {
      return false
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    pgrep.waitUntilExit()
    return pgrep.terminationStatus == 0 && !data.isEmpty
  }
}

private final class LoopbackEchoServer {
  private let descriptor: Int32
  let port: Int

  init() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_port = 0
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0, Darwin.listen(descriptor, 4) == 0 else {
      Darwin.close(descriptor)
      throw POSIXError(.EADDRINUSE)
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(descriptor, sockaddrPointer, &length)
      }
    }
    guard nameResult == 0 else {
      Darwin.close(descriptor)
      throw POSIXError(.EINVAL)
    }

    self.descriptor = descriptor
    port = Int(CFSwapInt16BigToHost(boundAddress.sin_port))
    DispatchQueue.global().async { [descriptor] in
      while true {
        let connection = accept(descriptor, nil, nil)
        guard connection >= 0 else { return }
        var bytes: [UInt8] = []
        while !bytes.contains(10) {
          var chunk = [UInt8](repeating: 0, count: 512)
          let received = chunk.withUnsafeMutableBytes { buffer in
            read(connection, buffer.baseAddress!, buffer.count)
          }
          guard received > 0 else { break }
          bytes.append(contentsOf: chunk.prefix(received))
        }
        if !bytes.isEmpty {
          bytes.withUnsafeBytes { buffer in
            _ = write(connection, buffer.baseAddress!, buffer.count)
          }
        }
        shutdown(connection, SHUT_RDWR)
        Darwin.close(connection)
      }
    }
  }

  deinit {
    shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
  }
}

extension RealSslocalSmokeTests {
  private func connectLoopback(port: Int) throws -> Int32 {
    let socketFD = socket(AF_INET, SOCK_STREAM, 0)
    guard socketFD >= 0 else { throw POSIXError(.ENOTSOCK) }
    var timeout = timeval(tv_sec: 5, tv_usec: 0)
    _ = setsockopt(
      socketFD, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_port = in_port_t(port).bigEndian
    let connectResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        connect(socketFD, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard connectResult == 0 else {
      Darwin.close(socketFD)
      throw POSIXError(.ECONNREFUSED)
    }
    return socketFD
  }

  private func performDirectSocksEcho(
    socksPort: Int, targetPort: Int, payload: [UInt8]
  ) throws -> [UInt8] {
    let socketFD = try connectLoopback(port: socksPort)
    defer { Darwin.close(socketFD) }
    let greeting: [UInt8] = [0x05, 0x01, 0x00]
    _ = try greeting.withUnsafeBytes { try writeAll(socketFD, $0) }
    XCTAssertEqual(try readExactly(socketFD, count: 2), [0x05, 0x00])

    let portBytes = UInt16(targetPort).bigEndian
    var request: [UInt8] = [0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1]
    withUnsafeBytes(of: portBytes) { request.append(contentsOf: $0) }
    _ = try request.withUnsafeBytes { try writeAll(socketFD, $0) }
    let reply = try readExactly(socketFD, count: 10)
    XCTAssertEqual(reply[1], 0, "空服务器直连模式应连接本地回环目标")

    _ = try payload.withUnsafeBytes { try writeAll(socketFD, $0) }
    return try readExactly(socketFD, count: payload.count)
  }

  private func performDirectHTTPEcho(
    httpPort: Int, targetPort: Int, payload: [UInt8]
  ) throws -> [UInt8] {
    let socketFD = try connectLoopback(port: httpPort)
    defer { Darwin.close(socketFD) }
    let request =
      "CONNECT 127.0.0.1:\(targetPort) HTTP/1.1\r\n"
      + "Host: 127.0.0.1:\(targetPort)\r\n\r\n"
    let requestBytes = Array(request.utf8)
    _ = try requestBytes.withUnsafeBytes { try writeAll(socketFD, $0) }

    var response: [UInt8] = []
    while response.count < 4 || Array(response.suffix(4)) != [13, 10, 13, 10] {
      response.append(contentsOf: try readExactly(socketFD, count: 1))
      guard response.count < 4096 else { throw NSError(domain: "smoke", code: 3) }
    }
    let header = String(decoding: response, as: UTF8.self)
    XCTAssertTrue(header.contains(" 200 "), "HTTP CONNECT 应答成功：\(header)")
    _ = try payload.withUnsafeBytes { try writeAll(socketFD, $0) }
    return try readExactly(socketFD, count: payload.count)
  }

  /// 对公网目标发起 SOCKS5 CONNECT，返回应答码；代理出口不可用时应答非 0
  /// 也算完成路由观测（不直连真实目标）。
  private func performSocksConnectReply(
    socksPort: Int, targetHost: String, targetPort: Int
  ) -> UInt8? {
    var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(targetHost.utf8.count)]
    request.append(contentsOf: targetHost.utf8)
    let portBytes = UInt16(targetPort).bigEndian
    withUnsafeBytes(of: portBytes) { request.append(contentsOf: $0) }
    return performSocksConnectReply(socksPort: socksPort, request: request)
  }

  private func performSocksConnectReply(socksPort: Int, request: [UInt8]) -> UInt8? {
    guard let socketFD = try? connectLoopback(port: socksPort) else { return nil }
    defer { Darwin.close(socketFD) }
    do {
      let greeting: [UInt8] = [0x05, 0x01, 0x00]
      _ = try greeting.withUnsafeBytes { try writeAll(socketFD, $0) }
      _ = try readExactly(socketFD, count: 2)
      _ = try request.withUnsafeBytes { try writeAll(socketFD, $0) }
      let reply = try readExactly(socketFD, count: 4)
      return reply[1]
    } catch {
      return nil
    }
  }

  /// 按给定 CONNECT 请求完成 SOCKS 会话并回显载荷；`successMessage` 用于
  /// 断言失败时点名场景。
  private func performSocksEcho(
    socksPort: Int, request: [UInt8], payload: [UInt8], successMessage: String
  ) throws -> [UInt8] {
    let socketFD = try connectLoopback(port: socksPort)
    defer { Darwin.close(socketFD) }
    let greeting: [UInt8] = [0x05, 0x01, 0x00]
    _ = try greeting.withUnsafeBytes { try writeAll(socketFD, $0) }
    XCTAssertEqual(try readExactly(socketFD, count: 2), [0x05, 0x00])
    _ = try request.withUnsafeBytes { try writeAll(socketFD, $0) }
    let reply = try readExactly(socketFD, count: 10)
    XCTAssertEqual(reply[1], 0, successMessage)
    _ = try payload.withUnsafeBytes { try writeAll(socketFD, $0) }
    return try readExactly(socketFD, count: payload.count)
  }

  private func socksDomainConnectRequest(host: String, port: Int) -> [UInt8] {
    var request: [UInt8] = [0x05, 0x01, 0x00, 0x03, UInt8(host.utf8.count)]
    request.append(contentsOf: host.utf8)
    let portBytes = UInt16(port).bigEndian
    withUnsafeBytes(of: portBytes) { request.append(contentsOf: $0) }
    return request
  }

  /// SOCKS5 CONNECT 到 IPv6 回环（ATYP=0x04）。
  private func socksIPv6ConnectRequest(port: Int) -> [UInt8] {
    var request: [UInt8] = [0x05, 0x01, 0x00, 0x04]
    request.append(contentsOf: Array(repeating: 0, count: 15))
    request.append(1)  // ::1
    let portBytes = UInt16(port).bigEndian
    withUnsafeBytes(of: portBytes) { request.append(contentsOf: $0) }
    return request
  }

  /// 对公网目标发起 HTTP CONNECT（应答头读到即返回，不要求成功）。
  private func performHTTPConnect(
    httpPort: Int, targetHost: String, targetPort: Int
  ) {
    guard let socketFD = try? connectLoopback(port: httpPort) else { return }
    defer { Darwin.close(socketFD) }
    do {
      let request =
        "CONNECT \(targetHost):\(targetPort) HTTP/1.1\r\n"
        + "Host: \(targetHost):\(targetPort)\r\n\r\n"
      let requestBytes = Array(request.utf8)
      _ = try requestBytes.withUnsafeBytes { try writeAll(socketFD, $0) }
      var response: [UInt8] = []
      while response.count < 4 || Array(response.suffix(4)) != [13, 10, 13, 10] {
        response.append(contentsOf: try readExactly(socketFD, count: 1))
        guard response.count < 4096 else { return }
      }
    } catch {
      return
    }
  }

  func testDirectACLRoutesSOCKSAndHTTPLocallyWithoutServers() throws {
    let echoServer = try LoopbackEchoServer()
    var ports = Set<Int>()
    while ports.count < 3 {
      let port = try grabEphemeralLoopbackPort()
      if port != echoServer.port { ports.insert(port) }
    }
    let selectedPorts = Array(ports)
    let listen = SslocalListenSettings(
      socksPort: selectedPorts[0], httpPort: selectedPorts[1], pacPort: selectedPorts[2])
    let document = SslocalRuntimeDocument(
      servers: [],
      listen: listen,
      acl: .direct(at: workDir.appendingPathComponent("sslocal-active.acl")))
    XCTAssertTrue(document.isWellFormed)
    let wrapper = try launchWrapper(document)
    defer {
      if wrapper.isRunning { kill(wrapper.processIdentifier, SIGTERM) }
    }

    XCTAssertTrue(
      try waitForCondition(timeout: 15) {
        EndpointHealthProbe.probe(host: "127.0.0.1", port: listen.socksPort, timeout: 1)
          == .reachable
          && EndpointHealthProbe.probe(host: "127.0.0.1", port: listen.httpPort, timeout: 1)
            == .reachable
      }, "直连模式应绑定 SOCKS 和 HTTP 入站")
    let runtimeStore = RuntimeFileStore(fileURL: contractURL)
    let receiptPublished = try waitForCondition(timeout: 30) {
      guard let receipt = runtimeStore.readRuntimeReceipt() else { return false }
      return receipt.contractSHA256 == document.deploymentSHA256
        && kill(receipt.processID, 0) == 0
    }
    XCTAssertTrue(receiptPublished, "应发布仍存活的 sslocal 子进程回执")
    let receipt = try XCTUnwrap(runtimeStore.readRuntimeReceipt())
    for local in document.locals {
      XCTAssertTrue(
        RuntimeSocketOwnershipProbe.process(
          receipt.processID, ownsTCPListenerOn: local.localPort),
        "回执对应的 sslocal 应拥有 \(local.inboundProtocol) TCP 监听")
    }
    XCTAssertEqual(
      runtimeStore.readRuntimeReceipt()?.contractSHA256,
      document.deploymentSHA256)

    let socksPayload = Array("socks direct\n".utf8)
    XCTAssertEqual(
      try performDirectSocksEcho(
        socksPort: listen.socksPort, targetPort: echoServer.port, payload: socksPayload),
      socksPayload,
      "空服务器列表下 SOCKS 应通过 bypass_all 直连回环目标")

    let httpPayload = Array("http direct\n".utf8)
    XCTAssertEqual(
      try performDirectHTTPEcho(
        httpPort: listen.httpPort, targetPort: echoServer.port, payload: httpPayload),
      httpPayload,
      "HTTP 入站应应用同一 ACL 并直连回环目标")

    kill(wrapper.processIdentifier, SIGTERM)
    let exited = XCTestExpectation(description: "direct wrapper exits")
    DispatchQueue.global().async {
      wrapper.waitUntilExit()
      exited.fulfill()
    }
    XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 10), .completed)
    XCTAssertEqual(wrapper.terminationStatus, 0)
    XCTAssertNil(runtimeStore.readRuntimeReceipt(), "停止后应清除运行回执")
  }

  /// 全局模式 ACL 路由（issue #62）：proxy_all + 固定本地绕过。本地目标经
  /// SOCKS/HTTP 直连（不触 SS 出口），公网目标默认走代理（SS 出口被连接）。
  /// 两个入站共用同一 ACL；IPv6 系统例外的局限由 ACL 路由兜底（见 ADR）。
  func testGlobalACLRoutesLocalDirectAndPublicThroughProxyOnSOCKSAndHTTP() throws {
    let echoServer = try LoopbackEchoServer()
    let fakeSSServer = try ConnectionCountingServer()
    var ports = Set<Int>()
    while ports.count < 3 {
      let port = try grabEphemeralLoopbackPort()
      if port != echoServer.port && port != fakeSSServer.port { ports.insert(port) }
    }
    let selectedPorts = Array(ports)
    let listen = SslocalListenSettings(
      socksPort: selectedPorts[0], httpPort: selectedPorts[1], pacPort: selectedPorts[2])
    let document = SslocalRuntimeDocument(
      servers: [
        SslocalServerDocument(
          id: "global-smoke-server",
          remarks: "global-smoke",
          server: "127.0.0.1",
          serverPort: fakeSSServer.port,
          password: "smoke-password",
          method: "aes-256-gcm",
          plugin: nil,
          pluginOpts: nil)
      ],
      listen: listen,
      acl: .global(at: workDir.appendingPathComponent("sslocal-active.acl")))
    XCTAssertTrue(document.isWellFormed)
    let wrapper = try launchWrapper(document)
    defer {
      if wrapper.isRunning { kill(wrapper.processIdentifier, SIGTERM) }
    }

    try awaitGlobalInboundsReady(listen: listen, document: document)

    try assertLocalTargetsBypass(listen: listen, echoPort: echoServer.port, fakeSS: fakeSSServer)
    try assertPublicTargetsProxy(listen: listen, fakeSS: fakeSSServer)
    try assertHostnameAndIPv6Bypass(
      listen: listen, echoPort: echoServer.port, fakeSS: fakeSSServer)

    kill(wrapper.processIdentifier, SIGTERM)
    let exited = XCTestExpectation(description: "global wrapper exits")
    DispatchQueue.global().async {
      wrapper.waitUntilExit()
      exited.fulfill()
    }
    XCTAssertEqual(XCTWaiter.wait(for: [exited], timeout: 10), .completed)
    XCTAssertEqual(wrapper.terminationStatus, 0)
    XCTAssertNil(
      RuntimeFileStore(fileURL: contractURL).readRuntimeReceipt(),
      "停止后应清除运行回执")
  }

  private func awaitGlobalInboundsReady(
    listen: SslocalListenSettings, document: SslocalRuntimeDocument
  ) throws {
    XCTAssertTrue(
      try waitForCondition(timeout: 15) {
        EndpointHealthProbe.probe(host: "127.0.0.1", port: listen.socksPort, timeout: 1)
          == .reachable
          && EndpointHealthProbe.probe(host: "127.0.0.1", port: listen.httpPort, timeout: 1)
            == .reachable
      }, "全局模式应绑定 SOCKS 和 HTTP 入站")
    let runtimeStore = RuntimeFileStore(fileURL: contractURL)
    XCTAssertTrue(
      try waitForCondition(timeout: 30) {
        guard let receipt = runtimeStore.readRuntimeReceipt() else { return false }
        return receipt.contractSHA256 == document.deploymentSHA256
          && kill(receipt.processID, 0) == 0
      }, "应发布仍存活的 sslocal 子进程回执")
  }

  private func assertLocalTargetsBypass(
    listen: SslocalListenSettings, echoPort: Int, fakeSS: ConnectionCountingServer
  ) throws {
    let socksPayload = Array("socks local\n".utf8)
    XCTAssertEqual(
      try performDirectSocksEcho(
        socksPort: listen.socksPort, targetPort: echoPort, payload: socksPayload),
      socksPayload,
      "全局 ACL 的本地绕过应让 SOCKS 直连回环目标")
    let httpPayload = Array("http local\n".utf8)
    XCTAssertEqual(
      try performDirectHTTPEcho(
        httpPort: listen.httpPort, targetPort: echoPort, payload: httpPayload),
      httpPayload,
      "HTTP 入站应应用同一 ACL 并直连回环目标")
    XCTAssertEqual(fakeSS.connectionCount, 0, "本地绕过不得触达 Shadowsocks 出口")
  }

  private func assertPublicTargetsProxy(
    listen: SslocalListenSettings, fakeSS: ConnectionCountingServer
  ) throws {
    let publicSocksReply = performSocksConnectReply(
      socksPort: listen.socksPort, targetHost: "8.8.8.8", targetPort: 53)
    XCTAssertNotNil(publicSocksReply, "公网目标应走代理路径")
    XCTAssertTrue(
      try waitForCondition(timeout: 5) { fakeSS.connectionCount >= 1 },
      "公网目标应连接 Shadowsocks 出口，而不是直连")
    let afterSocks = fakeSS.connectionCount

    performHTTPConnect(httpPort: listen.httpPort, targetHost: "1.1.1.1", targetPort: 443)
    XCTAssertTrue(
      try waitForCondition(timeout: 5) { fakeSS.connectionCount > afterSocks },
      "HTTP 入站的公网目标应同样连接 Shadowsocks 出口")
    XCTAssertTrue(
      fakeSS.connectionCount >= 2,
      "SOCKS 与 HTTP 对公网目标遵循同一 ACL 路由")
  }

  /// 主机名固定绕过与 IPv6 回环（AC2/AC5）。仅 localhost 保证解析到回环 echo；
  /// 其余主机名与 IPv6 只断言未触达 SS 出口——绕过路由已选定，直连解析失败
  /// 不改变路由事实，也不依赖不可靠的 IPv6 系统例外。
  private func assertHostnameAndIPv6Bypass(
    listen: SslocalListenSettings, echoPort: Int, fakeSS: ConnectionCountingServer
  ) throws {
    let afterPublic = fakeSS.connectionCount
    XCTAssertEqual(
      try performSocksEcho(
        socksPort: listen.socksPort,
        request: socksDomainConnectRequest(host: "localhost", port: echoPort),
        payload: Array("localhost\n".utf8),
        successMessage: "localhost 应绕过并直连"),
      Array("localhost\n".utf8))
    _ = performSocksConnectReply(
      socksPort: listen.socksPort,
      request: socksDomainConnectRequest(host: "printer.local", port: echoPort))
    _ = performSocksConnectReply(
      socksPort: listen.socksPort,
      request: socksDomainConnectRequest(host: "nas", port: echoPort))
    XCTAssertEqual(
      fakeSS.connectionCount, afterPublic,
      "localhost/*.local/无点主机名的固定绕过不得触达 Shadowsocks 出口")

    let afterHostnames = fakeSS.connectionCount
    _ = performSocksConnectReply(
      socksPort: listen.socksPort,
      request: socksIPv6ConnectRequest(port: echoPort))
    XCTAssertEqual(
      fakeSS.connectionCount, afterHostnames,
      "IPv6 本地目标不得触达 Shadowsocks 出口，由 ACL 路由兜底")
  }
}

/// 只接受 TCP 连接并计数的假 SS 服务器：证明目标被路由进代理出口，而非
/// 真实完成 Shadowsocks 握手（数据面属发布门槛人工验收）。
private final class ConnectionCountingServer {
  private let descriptor: Int32
  let port: Int
  private let counter = CounterBox()

  var connectionCount: Int { counter.value }

  init() throws {
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else { throw POSIXError(.ENOTSOCK) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
    address.sin_port = 0
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        Darwin.bind(descriptor, sockaddrPointer, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    guard bindResult == 0, Darwin.listen(descriptor, 8) == 0 else {
      Darwin.close(descriptor)
      throw POSIXError(.EADDRINUSE)
    }

    var boundAddress = sockaddr_in()
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    let nameResult = withUnsafeMutablePointer(to: &boundAddress) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPointer in
        getsockname(descriptor, sockaddrPointer, &length)
      }
    }
    guard nameResult == 0 else {
      Darwin.close(descriptor)
      throw POSIXError(.EINVAL)
    }

    self.descriptor = descriptor
    port = Int(CFSwapInt16BigToHost(boundAddress.sin_port))
    let counter = self.counter
    DispatchQueue.global().async { [descriptor] in
      while true {
        let connection = accept(descriptor, nil, nil)
        guard connection >= 0 else { return }
        counter.increment()
        // 立刻断开：sslocal 的 SS 握手会失败，但 TCP 连接已被观察到。
        shutdown(connection, SHUT_RDWR)
        Darwin.close(connection)
      }
    }
  }

  deinit {
    shutdown(descriptor, SHUT_RDWR)
    Darwin.close(descriptor)
  }

  private final class CounterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
      lock.lock()
      defer { lock.unlock() }
      return count
    }

    func increment() {
      lock.lock()
      count += 1
      lock.unlock()
    }
  }
}
