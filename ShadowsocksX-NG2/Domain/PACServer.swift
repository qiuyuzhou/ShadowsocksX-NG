import Foundation
import Network

enum PACServerError: Error, Equatable {
  case invalidPort(Int)
  case startFailed(String)
  case startTimedOut
}

/// Network.framework 上的最小 HTTP/1.1 PAC 服务。暴露面严格限制为一个 GET
/// 路径；不提供文件系统映射、目录遍历、请求体或持久连接（issue #28）。
final class PACServer {
  private static let maximumHeaderBytes = 8 * 1024
  private static let maximumConnections = 64

  private let configuration: PACRuntimeDocument
  private let requestHeaderTimeout: TimeInterval
  private let queue = DispatchQueue(label: "com.qiuyuzhou.ShadowsocksX-NG2.pac")
  private let lock = NSLock()
  private var listener: NWListener?
  /// 只在 queue 上访问；停止时一并取消，避免 listener 已停但旧连接仍可取 PAC。
  private var connections: [ObjectIdentifier: NWConnection] = [:]

  init(configuration: PACRuntimeDocument, requestHeaderTimeout: TimeInterval = 5) {
    self.configuration = configuration
    self.requestHeaderTimeout = requestHeaderTimeout
  }

  func start(timeout: TimeInterval = 5) throws {
    guard
      (1...65535).contains(configuration.port),
      let port = NWEndpoint.Port(rawValue: UInt16(configuration.port))
    else { throw PACServerError.invalidPort(configuration.port) }

    lock.lock()
    guard listener == nil else {
      lock.unlock()
      return
    }
    lock.unlock()

    let parameters = NWParameters.tcp
    parameters.requiredLocalEndpoint = .hostPort(
      host: NWEndpoint.Host(configuration.bindAddress), port: port)
    let newListener: NWListener
    do {
      newListener = try NWListener(using: parameters)
    } catch {
      throw PACServerError.startFailed(String(describing: error))
    }

    let started = DispatchSemaphore(value: 0)
    let state = StartState()
    newListener.stateUpdateHandler = { update in
      switch update {
      case .ready:
        state.finish()
        started.signal()
      case .failed(let error):
        state.finish(error: error)
        started.signal()
      default:
        break
      }
    }
    newListener.newConnectionHandler = { [weak self] connection in
      self?.accept(connection)
    }

    lock.lock()
    listener = newListener
    lock.unlock()
    newListener.start(queue: queue)

    guard started.wait(timeout: .now() + timeout) == .success else {
      stop()
      throw PACServerError.startTimedOut
    }
    if let error = state.error {
      stop()
      throw PACServerError.startFailed(String(describing: error))
    }
  }

  func stop(timeout: TimeInterval = 2) {
    lock.lock()
    guard let current = listener else {
      lock.unlock()
      return
    }
    listener = nil
    lock.unlock()

    let stopped = DispatchSemaphore(value: 0)
    current.stateUpdateHandler = { state in
      switch state {
      case .cancelled, .failed:
        stopped.signal()
      default:
        break
      }
    }
    current.cancel()
    _ = stopped.wait(timeout: .now() + timeout)
    queue.sync {
      for connection in connections.values {
        connection.cancel()
      }
      connections.removeAll()
    }
  }

  private func accept(_ connection: NWConnection) {
    guard connections.count < Self.maximumConnections else {
      connection.cancel()
      return
    }
    connections[ObjectIdentifier(connection)] = connection
    let deadline = DispatchWorkItem { [weak self, weak connection] in
      guard let self, let connection else { return }
      finish(connection)
    }
    queue.asyncAfter(deadline: .now() + requestHeaderTimeout, execute: deadline)
    connection.start(queue: queue)
    receiveRequest(on: connection, accumulated: Data(), deadline: deadline)
  }

  private func receiveRequest(
    on connection: NWConnection,
    accumulated: Data,
    deadline: DispatchWorkItem
  ) {
    connection.receive(
      minimumIncompleteLength: 1,
      maximumLength: Self.maximumHeaderBytes - accumulated.count
    ) { [weak self] data, _, isComplete, error in
      guard let self else {
        connection.cancel()
        return
      }
      var request = accumulated
      if let data {
        request.append(data)
      }
      if request.count >= Self.maximumHeaderBytes {
        send(.requestHeaderFieldsTooLarge, on: connection, deadline: deadline)
        return
      }
      if request.range(of: Data("\r\n\r\n".utf8)) != nil {
        send(response(for: request), on: connection, deadline: deadline)
        return
      }
      if error != nil || isComplete {
        send(.badRequest, on: connection, deadline: deadline)
        return
      }
      receiveRequest(on: connection, accumulated: request, deadline: deadline)
    }
  }

  private func response(for data: Data) -> HTTPResponse {
    guard let request = String(data: data, encoding: .utf8) else { return .badRequest }
    let lines = request.components(separatedBy: "\r\n")
    guard let requestLine = lines.first else { return .badRequest }
    let components = requestLine.split(separator: " ", omittingEmptySubsequences: false)
    guard components.count == 3, components[2] == "HTTP/1.1" else { return .badRequest }

    let headers = lines.dropFirst().prefix { !$0.isEmpty }
    let parsedHeaders = headers.compactMap { line -> (name: String, value: String)? in
      let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
      guard parts.count == 2 else { return nil }
      let name = parts[0].trimmingCharacters(in: .whitespaces)
      guard !name.isEmpty, !name.contains(" ") else { return nil }
      return (name.lowercased(), parts[1].trimmingCharacters(in: .whitespaces))
    }
    guard parsedHeaders.count == headers.count else { return .badRequest }
    guard parsedHeaders.contains(where: { $0.name == "host" && !$0.value.isEmpty }) else {
      return .badRequest
    }

    guard components[0] == "GET" else { return .methodNotAllowed }
    guard components[1] == Substring(configuration.endpointPath) else { return .notFound }
    return .ok(body: Data(configuration.javaScript.utf8))
  }

  private func send(
    _ response: HTTPResponse,
    on connection: NWConnection,
    deadline: DispatchWorkItem
  ) {
    deadline.cancel()
    connection.send(
      content: response.data,
      completion: .contentProcessed { [weak self, weak connection] _ in
        guard let self, let connection else { return }
        queue.async { self.finish(connection) }
      })
  }

  private func finish(_ connection: NWConnection) {
    connection.cancel()
    connections.removeValue(forKey: ObjectIdentifier(connection))
  }
}

private final class StartState: @unchecked Sendable {
  private let lock = NSLock()
  private var storedError: NWError?

  var error: NWError? {
    lock.lock()
    defer { lock.unlock() }
    return storedError
  }

  func finish(error: NWError? = nil) {
    lock.lock()
    storedError = error
    lock.unlock()
  }
}

private struct HTTPResponse {
  let status: String
  let headers: [(String, String)]
  let body: Data

  static func ok(body: Data) -> HTTPResponse {
    HTTPResponse(
      status: "200 OK",
      headers: [
        ("Content-Type", "application/x-ns-proxy-autoconfig"),
        ("Cache-Control", "no-store"),
      ],
      body: body)
  }

  static let badRequest = HTTPResponse(status: "400 Bad Request")
  static let notFound = HTTPResponse(status: "404 Not Found")
  static let methodNotAllowed = HTTPResponse(
    status: "405 Method Not Allowed", headers: [("Allow", "GET")])
  static let requestHeaderFieldsTooLarge = HTTPResponse(
    status: "431 Request Header Fields Too Large")

  init(status: String, headers: [(String, String)] = [], body: Data = Data()) {
    self.status = status
    self.headers = headers
    self.body = body
  }

  var data: Data {
    var lines = ["HTTP/1.1 \(status)"]
    lines.append(contentsOf: headers.map { "\($0.0): \($0.1)" })
    lines.append("Content-Length: \(body.count)")
    lines.append("Connection: close")
    lines.append("")
    lines.append("")
    var result = Data(lines.joined(separator: "\r\n").utf8)
    result.append(body)
    return result
  }
}
