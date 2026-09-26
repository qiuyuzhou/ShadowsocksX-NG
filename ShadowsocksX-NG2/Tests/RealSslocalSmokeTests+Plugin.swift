import Darwin
import XCTest

@testable import ShadowsocksX_NG2

extension RealSslocalSmokeTests {
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
    while ports.count < 2 {
      ports.insert(try grabEphemeralLoopbackPort())
    }
    let selectedPorts = Array(ports)
    let socksPort = selectedPorts[0]
    let httpPort = selectedPorts[1]
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
        socksPort: socksPort, httpPort: httpPort))
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
