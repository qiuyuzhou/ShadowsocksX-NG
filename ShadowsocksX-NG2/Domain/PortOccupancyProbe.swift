import Darwin
import Foundation

/// 端口占用判定结果。空闲与占用之外还有「无法判定」：绑定测试自身失败
/// （地址不可解析、特权端口等）时如实呈现，不冒充空闲。
enum PortOccupancy: Equatable, Sendable {
  case free
  /// 端口不可绑定；占用进程名为尽力解析（未知为 nil，D8「尽力而为」）。
  case occupied(occupier: String?)
  case unknown(detail: String)
}

/// 端口占用探测缝（issue #30）：设置编辑期的即时占用校验。激活是否成功
/// 仍以 runtime 实际绑定为准（#29 健康门禁），本探测不构成权威判定。
protocol PortOccupancyProbing: Sendable {
  func occupancy(port: Int, bindAddress: String) -> PortOccupancy
}

/// 系统实现：对 `bindAddress:port` 做一次不带复用选项的 TCP bind——能绑定
/// 即空闲，`EADDRINUSE` 即占用；占用时尽力以 `lsof` 解析监听进程名。探测
/// 不设置 SO_REUSEADDR/SO_REUSEPORT，避免 Legacy 式复用残留的假空闲。
struct SystemPortOccupancyProbe: PortOccupancyProbing {
  func occupancy(port: Int, bindAddress: String) -> PortOccupancy {
    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(port).bigEndian
    guard inet_pton(AF_INET, bindAddress, &address.sin_addr) == 1 else {
      return .unknown(detail: "监听地址无法解析")
    }
    let descriptor = socket(AF_INET, SOCK_STREAM, 0)
    guard descriptor >= 0 else {
      return .unknown(detail: String(cString: strerror(errno)))
    }
    defer { close(descriptor) }
    let bindResult = withUnsafePointer(to: &address) { pointer in
      pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
      }
    }
    if bindResult == 0 { return .free }
    if errno == EADDRINUSE {
      return .occupied(occupier: Self.occupierProcessName(port: port))
    }
    return .unknown(detail: String(cString: strerror(errno)))
  }

  /// `lsof` 尽力解析监听进程名：本产品代理进程与 GUI 同用户运行，无需特权；
  /// lsof 缺失、失败或无匹配时返回 nil，不影响占用判定本身。
  static func occupierProcessName(port: Int) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
    process.arguments = ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = Pipe()
    do {
      try process.run()
    } catch {
      return nil
    }
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return occupierProcessName(fromLsofOutput: String(data: data, encoding: .utf8) ?? "")
  }

  /// 从 lsof 输出解析第一个数据行的进程名（首字段）；表头与空行跳过。
  static func occupierProcessName(fromLsofOutput output: String) -> String? {
    for line in output.split(whereSeparator: \.isNewline) {
      let fields = line.split(
        maxSplits: 1, omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
      guard let name = fields.first, name != "COMMAND" else { continue }
      return String(name)
    }
    return nil
  }
}
