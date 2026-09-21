import Darwin
import Foundation

/// Legacy 交接（spec #21 D12，issue #37）：与导入分离的第二阶段。用户明确确认
/// 「切换到 2.0」后，按硬编码白名单停用三个 Legacy launchd label（全历史无变
/// 体，见 docs/research/wayfinder-issue-17-legacy-handoff.md §1）——不泛匹配、
/// 不 pkill；前置确认旧版 app 已退出（其 GUI 进程持有 PAC 端口，bootout 不释
/// 放），端口释放确认通过后才允许启动 2.0；Legacy 数据一律不删除，残留仅提示。
enum LegacyLaunchAgentLabel: String, CaseIterable, Sendable {
  case local = "com.qiuyuzhou.shadowsocksX-NG.local"
  case http = "com.qiuyuzhou.shadowsocksX-NG.http"
  case kcptun = "com.qiuyuzhou.shadowsocksX-NG.kcptun"
}

/// Legacy 三端口的配置值（只读读取，属于 Legacy 数据——只读、不删改）。
struct LegacyListenPorts: Equatable, Sendable {
  var socksPort: Int = 1086
  var httpPort: Int = 1087
  var pacPort: Int = 1089
  var socksAddress: String = "127.0.0.1"
}

protocol LegacyListenPortsProviding: Sendable {
  func currentPorts() -> LegacyListenPorts
}

/// 从 Legacy defaults 域读取端口（inventory §1：端口不在 LaunchAgent plist 内，
/// 用户自定义值在 defaults）。缺失或无效回落出厂三端口，不改写任何值。
/// UserDefaults 线程安全（Apple 文档），Sendable 依存性核对为安全。
struct UserDefaultsLegacyListenPortsProvider: LegacyListenPortsProviding, @unchecked Sendable {
  static let legacyBundleIdentifier = "com.qiuyuzhou.ShadowsocksX-NG"

  let defaults: UserDefaults
  let bundleIdentifier: String

  init(
    defaults: UserDefaults = .standard,
    bundleIdentifier: String = UserDefaultsLegacyListenPortsProvider.legacyBundleIdentifier
  ) {
    self.defaults = defaults
    self.bundleIdentifier = bundleIdentifier
  }

  func currentPorts() -> LegacyListenPorts {
    let domain = defaults.persistentDomain(forName: bundleIdentifier) ?? [:]
    func port(_ key: String, fallback: Int) -> Int {
      guard let number = domain[key] as? NSNumber else { return fallback }
      let value = number.intValue
      return (1...65_535).contains(value) ? value : fallback
    }
    let address = (domain["LocalSocks5.ListenAddress"] as? String)?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return LegacyListenPorts(
      socksPort: port("LocalSocks5.ListenPort", fallback: 1086),
      httpPort: port("LocalHTTP.ListenPort", fallback: 1087),
      pacPort: port("PacServer.ListenPort", fallback: 1089),
      socksAddress: (address?.isEmpty == false) ? address! : "127.0.0.1")
  }
}

// MARK: - 系统代理归属判定（特征值）

/// Legacy 特征判定结果：`.none` 无启用代理；`.legacy` 全部启用面与 Legacy 写
/// 入特征匹配；`.other` 存在非 Legacy 特征（未知所有者，不覆盖——D12）。
enum LegacyProxyOwnershipClass: Equatable, Sendable {
  case none
  case legacy
  case other
}

/// 系统代理无所有者标记（wayfinder #17 §5.1），归属 = 特征值匹配。特征镜像
/// Legacy 自身 `proxy_conf_helper` off 模式的判定（main.m:191-202）：本地 PAC
/// URL 恰为 `http://localhost:<pacPort>/proxy.pac`（host 硬编码 localhost），
/// SOCKS 为其监听地址与端口，HTTP/HTTPS 为 Privoxy 地址与端口。任一启用面不
/// 匹配（含混合）即按未知所有者处理。2.0 自身写 `/v1/proxy.pac`，不会碰撞。
enum LegacySystemProxySignature {
  static let pacPath = "/proxy.pac"
  static let httpProxy = "HTTPProxy"
  static let httpPort = "HTTPPort"
  static let httpsProxy = "HTTPSProxy"
  static let httpsPort = "HTTPSPort"

  /// Legacy off 模式写入的静止形态：全部禁用。
  static let emptyDisabled: [String: Any] = [
    SystemProxyPropertyList.httpEnabled: 0,
    SystemProxyPropertyList.httpsEnabled: 0,
    SystemProxyPropertyList.pacEnabled: 0,
    SystemProxyPropertyList.socksEnabled: 0,
    SystemProxyPropertyList.exceptionsList: [String](),
  ]

  static func legacyPACURL(port: Int) -> String {
    "http://localhost:\(port)\(pacPath)"
  }

  static func classify(
    _ dictionary: [String: Any], ports: LegacyListenPorts
  ) -> LegacyProxyOwnershipClass {
    var sawEnabledFacet = false

    if intValue(dictionary[SystemProxyPropertyList.pacEnabled]) == 1 {
      sawEnabledFacet = true
      guard
        stringValue(dictionary[SystemProxyPropertyList.pacURL]) == legacyPACURL(port: ports.pacPort)
      else { return .other }
    }
    if intValue(dictionary[SystemProxyPropertyList.socksEnabled]) == 1 {
      sawEnabledFacet = true
      guard
        isEquivalentHost(
          stringValue(dictionary[SystemProxyPropertyList.socksProxy]), to: ports.socksAddress),
        intValue(dictionary[SystemProxyPropertyList.socksPort]) == ports.socksPort
      else { return .other }
    }
    if intValue(dictionary[SystemProxyPropertyList.httpEnabled]) == 1 {
      sawEnabledFacet = true
      guard
        isLoopbackHost(stringValue(dictionary[httpProxy])),
        intValue(dictionary[httpPort]) == ports.httpPort
      else { return .other }
    }
    if intValue(dictionary[SystemProxyPropertyList.httpsEnabled]) == 1 {
      sawEnabledFacet = true
      guard
        isLoopbackHost(stringValue(dictionary[httpsProxy])),
        intValue(dictionary[httpsPort]) == ports.httpPort
      else { return .other }
    }
    return sawEnabledFacet ? .legacy : .none
  }

  /// 清理投影：只处理**启用**且归属匹配的代理面——禁用面的端点值可能是
  /// 用户或其他软件的静止数据（Legacy helper 整字典替换的写入形态下不会与
  /// Legacy 特征共存，但手工混入可能），一律不动；绕过列表等其余键保留。
  /// 幂等。
  static func cleaned(_ dictionary: [String: Any]) -> [String: Any] {
    var result = dictionary
    let enabledFacets: [(enableKey: String, endpointKeys: [String])] = [
      (
        SystemProxyPropertyList.pacEnabled,
        [SystemProxyPropertyList.pacURL, SystemProxyPropertyList.pacJavaScript]
      ),
      (
        SystemProxyPropertyList.socksEnabled,
        [SystemProxyPropertyList.socksProxy, SystemProxyPropertyList.socksPort]
      ),
      (SystemProxyPropertyList.httpEnabled, [httpProxy, httpPort]),
      (SystemProxyPropertyList.httpsEnabled, [httpsProxy, httpsPort]),
    ]
    for facet in enabledFacets {
      guard intValue(dictionary[facet.enableKey]) == 1 else { continue }
      result[facet.enableKey] = 0
      for key in facet.endpointKeys {
        result.removeValue(forKey: key)
      }
    }
    return result
  }

  private static let loopbackWrites: Set<String> = ["127.0.0.1", "localhost", "::1"]

  /// 127.0.0.1 / localhost / ::1 视为同一回环写法；其余按大小写不敏感全等。
  static func isEquivalentHost(_ actual: String?, to expected: String) -> Bool {
    guard let actual, !actual.isEmpty else { return false }
    let normalizedActual = actual.lowercased()
    let normalizedExpected = expected.lowercased()
    if normalizedActual == normalizedExpected { return true }
    return loopbackWrites.contains(normalizedActual)
      && loopbackWrites.contains(normalizedExpected)
  }

  static func isLoopbackHost(_ actual: String?) -> Bool {
    guard let actual, !actual.isEmpty else { return false }
    return loopbackWrites.contains(actual.lowercased())
  }

  private static func intValue(_ value: Any?) -> Int? {
    (value as? NSNumber)?.intValue
  }

  private static func stringValue(_ value: Any?) -> String? {
    value as? String
  }
}

// MARK: - launchctl 命令缝

struct LaunchctlOutcome: Equatable, Sendable {
  let exitCode: Int32
  let stderr: String
}

/// `launchctl print` 的状态判定只依赖退出码（man 明文 print 输出结构非 API，
/// 不解析文本）：0 已加载、113 不存在、其余未知。
enum LaunchctlServiceState: Equatable, Sendable {
  case loaded
  case notLoaded
  case unknown(detail: String)
}

protocol LaunchctlControlling: Sendable {
  func serviceState(label: String) -> LaunchctlServiceState
  func bootout(label: String) -> LaunchctlOutcome
  func disable(label: String) -> LaunchctlOutcome
  func kill(label: String, signal: Int32) -> LaunchctlOutcome
}

/// 系统实现：gui 域按 service target 操作（`gui/<uid>/<label>`），bootout 不
/// 需要 plist 文件存在，覆盖「job 已加载但 plist 缺失」的错位形态。
struct ProcessLaunchctlController: LaunchctlControlling {
  static let executableURL = URL(fileURLWithPath: "/bin/launchctl")

  func serviceState(label: String) -> LaunchctlServiceState {
    let outcome = Self.run(["print", Self.serviceTarget(label)])
    switch outcome.exitCode {
    case 0: return .loaded
    case 113: return .notLoaded
    default: return .unknown(detail: outcome.stderr)
    }
  }

  func bootout(label: String) -> LaunchctlOutcome {
    Self.run(["bootout", Self.serviceTarget(label)])
  }

  func disable(label: String) -> LaunchctlOutcome {
    // 跨启动持久的 override：阻止残留 plist（含 KeepAlive 形态）在下次登录
    // 复活；Legacy 自身用 `load -w`，重装可自行覆盖 disabled 状态。
    Self.run(["disable", Self.serviceTarget(label)])
  }

  func kill(label: String, signal: Int32) -> LaunchctlOutcome {
    Self.run(["kill", String(signal), Self.serviceTarget(label)])
  }

  private static func serviceTarget(_ label: String) -> String {
    "gui/\(getuid())/\(label)"
  }

  static func run(_ arguments: [String]) -> LaunchctlOutcome {
    let process = Process()
    process.executableURL = executableURL
    process.arguments = arguments
    let stdoutPipe = Pipe()
    let stderrPipe = Pipe()
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe
    do {
      try process.run()
    } catch {
      return LaunchctlOutcome(exitCode: -1, stderr: String(describing: error))
    }
    // print 的 stdout 可能超过管道缓冲：并发排空，避免顺序读死锁。
    let stderrQueue = DispatchQueue.global(qos: .utility)
    var stderrData = Data()
    let group = DispatchGroup()
    group.enter()
    stderrQueue.async {
      stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      group.leave()
    }
    _ = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
    group.wait()
    process.waitUntilExit()
    return LaunchctlOutcome(
      exitCode: process.terminationStatus,
      stderr: String(data: stderrData, encoding: .utf8) ?? "")
  }
}

// MARK: - 残留 plist 检查

/// 磁盘残留 plist 状态。活跃性必须读内容判断：2017 前的生成代码带 KeepAlive，
/// 这类残留每次登录自动拉起并在退出后重启（wayfinder #17 §2.2）。
struct LegacyAgentPlistResidue: Equatable, Sendable {
  let label: String
  let fileExists: Bool
  let keepAlive: Bool
  let runAtLoad: Bool
  var contentReadable: Bool = true

  var isActiveForm: Bool { keepAlive || runAtLoad }
}

protocol LegacyAgentPlistInspecting: Sendable {
  func residue(for label: String) -> LegacyAgentPlistResidue
}

struct FileSystemLegacyAgentPlistInspector: LegacyAgentPlistInspecting {
  static var launchAgentsDirectory: URL {
    FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/LaunchAgents", isDirectory: true)
  }

  func residue(for label: String) -> LegacyAgentPlistResidue {
    let url = Self.launchAgentsDirectory.appendingPathComponent(label + ".plist")
    guard FileManager.default.fileExists(atPath: url.path) else {
      return LegacyAgentPlistResidue(
        label: label, fileExists: false, keepAlive: false, runAtLoad: false)
    }
    guard
      let data = try? Data(contentsOf: url),
      let plist = try? PropertyListSerialization.propertyList(
        from: data, options: [], format: nil) as? [String: Any]
    else {
      return LegacyAgentPlistResidue(
        label: label, fileExists: true, keepAlive: false, runAtLoad: false,
        contentReadable: false)
    }
    return LegacyAgentPlistResidue(
      label: label,
      fileExists: true,
      keepAlive: Self.isActiveFlag(plist["KeepAlive"]),
      runAtLoad: Self.isActiveFlag(plist["RunAtLoad"]))
  }

  /// KeepAlive 可以是布尔，也可以是条件字典；非 false 即视为活跃形态。
  private static func isActiveFlag(_ value: Any?) -> Bool {
    if let number = value as? NSNumber { return number.boolValue }
    if value is [String: Any] { return true }
    return false
  }
}

// MARK: - 旧版 app 检测缝

protocol LegacyAppControlling: Sendable {
  func isRunning() -> Bool
  func isInstalled() -> Bool
  func requestGracefulQuit() -> Bool
}

// MARK: - 检测、计划与报告

struct LegacyHandoffDetection: Equatable, Sendable {
  let loadedLabels: [String]
  /// print 退出码既非 0 也非 113 的 label（状态未知，必须中止而非猜测）。
  let printFailures: [String]
  let plists: [LegacyAgentPlistResidue]
  let legacyAppRunning: Bool
  let legacyAppInstalled: Bool
  let ports: LegacyListenPorts
}

enum LegacyHandoffAction: Equatable, Sendable {
  case bootout(label: String)
  case disable(label: String)
}

struct LegacyHandoffPlan: Equatable, Sendable {
  let actions: [LegacyHandoffAction]
  let residue: [LegacyAgentPlistResidue]

  static func make(from detection: LegacyHandoffDetection) -> LegacyHandoffPlan {
    var actions: [LegacyHandoffAction] = []
    var residue: [LegacyAgentPlistResidue] = []
    for label in LegacyLaunchAgentLabel.allCases {
      if detection.loadedLabels.contains(label.rawValue) {
        actions.append(.bootout(label: label.rawValue))
      }
      if let plist = detection.plists.first(where: { $0.label == label.rawValue }),
        plist.fileExists
      {
        residue.append(plist)
        actions.append(.disable(label: label.rawValue))
      }
    }
    return LegacyHandoffPlan(actions: actions, residue: residue)
  }
}

struct LegacyHandoffReport: Equatable, Sendable {
  let bootedOutLabels: [String]
  let killedLabels: [String]
  let disabledLabels: [String]
  let residue: [LegacyAgentPlistResidue]
  let proxyServicesCleaned: [String]
  let proxyServicesUntouchedUnknownOwner: [String]
  let confirmedFreePorts: [Int]
}

enum LegacyHandoffError: Error, Equatable {
  case legacyAppRunning
  case detectionFailed(detail: String)
  case proxyCleanFailed(detail: String)
  case bootoutFailed(label: String, detail: String)
  case disableFailed(label: String, detail: String)
  case portsNotReleased(occupied: [String])

  var presentedReason: String {
    switch self {
    case .legacyAppRunning:
      "请先退出旧版 ShadowsocksX-NG app（它占用着 PAC 端口，卸载后台服务不会释放），再执行交接"
    case .detectionFailed(let detail):
      "无法确认旧版后台服务状态，已中止交接：\(detail)"
    case .proxyCleanFailed(let detail):
      "系统代理清理未完成，已中止且未改动任何旧版后台服务：\(detail)"
    case .bootoutFailed(let label, let detail):
      "无法停用旧版后台服务 \(label)：\(detail)"
    case .disableFailed(let label, let detail):
      "无法阻止旧版后台服务 \(label) 在下次登录时自动加载：\(detail)"
    case .portsNotReleased(let occupied):
      "旧版监听端口未释放，2.0 未启动：" + occupied.joined(separator: "、")
    }
  }
}

// MARK: - 系统代理清理缝

struct LegacyProxyCleanOutcome: Equatable, Sendable {
  let cleanedServiceIDs: [String]
  let unknownOwnerServiceIDs: [String]
}

protocol LegacyProxyCleaning: Sendable {
  /// 只改写归属判定为 Legacy 的网络服务；未知所有者原样保留并点名返回。
  func cleanLegacyOwnedProxy(ports: LegacyListenPorts) throws -> LegacyProxyCleanOutcome
}

// MARK: - 完成标记

protocol LegacyHandoffMarkerStoring: Sendable {
  func isCompleted() -> Bool
  func setCompleted(_ completed: Bool) throws
}

struct UserDefaultsLegacyHandoffMarkerStore: LegacyHandoffMarkerStoring, @unchecked Sendable {
  static let key = "legacyHandoff.completed"

  let defaults: UserDefaults

  init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
  }

  func isCompleted() -> Bool {
    defaults.bool(forKey: Self.key)
  }

  func setCompleted(_ completed: Bool) throws {
    if completed {
      defaults.set(true, forKey: Self.key)
    } else {
      defaults.removeObject(forKey: Self.key)
    }
  }
}

// MARK: - 交接服务

/// 交接时序（wayfinder #17 §8）：前置退出检查 → 识别 → 系统代理清理（授权在
/// 最前，失败即零影响中止）→ 白名单 bootout（print 退出码验证，kill 有文档
/// 后备）→ 残留 plist disable → 端口释放门禁 → 写完成标记。启动 2.0 属于交
/// 接之后的独立动作，端口门禁失败即不启动。
struct LegacyHandoffService: Sendable {
  let launchctl: LaunchctlControlling
  let plistInspector: LegacyAgentPlistInspecting
  let appController: LegacyAppControlling
  let portsProvider: LegacyListenPortsProviding
  let occupancyProbe: PortOccupancyProbing
  let proxyCleaner: LegacyProxyCleaning
  let marker: LegacyHandoffMarkerStoring
  var portPollAttempts: Int = 20
  var portPollIntervalNanoseconds: UInt64 = 500_000_000
  var removalVerifyAttempts: Int = 5
  var removalVerifyIntervalNanoseconds: UInt64 = 200_000_000

  func isCompleted() -> Bool {
    marker.isCompleted()
  }

  /// 只读识别（确认前展示状态用）；不写任何 launchd 状态、不动 Legacy 数据。
  func detect() -> LegacyHandoffDetection {
    var loadedLabels: [String] = []
    var printFailures: [String] = []
    for label in LegacyLaunchAgentLabel.allCases {
      switch launchctl.serviceState(label: label.rawValue) {
      case .loaded:
        loadedLabels.append(label.rawValue)
      case .notLoaded:
        break
      case .unknown(let detail):
        printFailures.append("\(label.rawValue)（\(detail)）")
      }
    }
    let plists = LegacyLaunchAgentLabel.allCases.map { label in
      plistInspector.residue(for: label.rawValue)
    }
    return LegacyHandoffDetection(
      loadedLabels: loadedLabels,
      printFailures: printFailures,
      plists: plists,
      legacyAppRunning: appController.isRunning(),
      legacyAppInstalled: appController.isInstalled(),
      ports: portsProvider.currentPorts())
  }

  func performHandoff() async throws -> LegacyHandoffReport {
    guard !appController.isRunning() else {
      throw LegacyHandoffError.legacyAppRunning
    }
    RuntimeLog.emit(.legacyHandoffStarted)

    let detection = detect()
    if let failure = detection.printFailures.first {
      throw LegacyHandoffError.detectionFailed(detail: failure)
    }
    let plan = LegacyHandoffPlan.make(from: detection)

    // 1) 系统代理先清理：授权交互在最前；失败即中止，一个 job 都不动，
    //    避免「服务已停、代理仍指向死端口」的断网中间态。
    let cleanOutcome = try cleanSystemProxy(ports: detection.ports)

    // 2) 按计划执行白名单动作（bootout + 残留 plist disable）。
    let execution = try await execute(plan.actions)

    // 3) 端口释放门禁：无复用选项的 bind 探测（禁 SO_REUSEPORT——Legacy
    //    ss-local 带 --reuse-port，复用探测会假成功）。
    let confirmedFreePorts = try await confirmPortsReleased(detection.ports)

    // 完成标记失败不推翻交接事实（停用已生效、重跑已实弹验证为幂等）：
    // 记入诊断日志，完成态照常返回。
    do {
      try marker.setCompleted(true)
    } catch {
      RuntimeLog.emit(.runtimePersistFailed(detail: String(describing: error)))
    }
    RuntimeLog.emit(.legacyHandoffCompleted)

    return LegacyHandoffReport(
      bootedOutLabels: execution.bootedOutLabels,
      killedLabels: execution.killedLabels,
      disabledLabels: execution.disabledLabels,
      residue: plan.residue,
      proxyServicesCleaned: cleanOutcome.cleanedServiceIDs,
      proxyServicesUntouchedUnknownOwner: cleanOutcome.unknownOwnerServiceIDs,
      confirmedFreePorts: confirmedFreePorts)
  }

  // MARK: - 私有步骤

  private func cleanSystemProxy(ports: LegacyListenPorts) throws -> LegacyProxyCleanOutcome {
    let outcome: LegacyProxyCleanOutcome
    do {
      outcome = try proxyCleaner.cleanLegacyOwnedProxy(ports: ports)
    } catch let error as LegacyHandoffError {
      throw error
    } catch {
      throw LegacyHandoffError.proxyCleanFailed(detail: String(describing: error))
    }
    if !outcome.cleanedServiceIDs.isEmpty {
      RuntimeLog.emit(.legacyHandoffProxyCleaned(serviceCount: outcome.cleanedServiceIDs.count))
    }
    return outcome
  }

  private struct PlanExecution {
    var bootedOutLabels: [String] = []
    var killedLabels: [String] = []
    var disabledLabels: [String] = []
  }

  /// 逐动作执行：bootout（print 退出码验证，kill 有文档后备）与 disable；
  /// 任一动作失败即抛错中止后续动作与端口门禁（2.0 不启动）。
  private func execute(_ actions: [LegacyHandoffAction]) async throws -> PlanExecution {
    var execution = PlanExecution()
    for action in actions {
      switch action {
      case .bootout(let label):
        switch await removeJob(label) {
        case .removed:
          execution.bootedOutLabels.append(label)
        case .removedAfterKill:
          execution.bootedOutLabels.append(label)
          execution.killedLabels.append(label)
        case .failure(let detail):
          RuntimeLog.emit(.legacyHandoffFailed(reason: detail))
          throw LegacyHandoffError.bootoutFailed(label: label, detail: detail)
        }
      case .disable(let label):
        let outcome = launchctl.disable(label: label)
        guard outcome.exitCode == 0 else {
          let detail = Self.describeOutcome(outcome)
          RuntimeLog.emit(.legacyHandoffFailed(reason: detail))
          throw LegacyHandoffError.disableFailed(label: label, detail: detail)
        }
        execution.disabledLabels.append(label)
        RuntimeLog.emit(.legacyHandoffLabelDisabled(label: label))
      }
    }
    return execution
  }

  private static func describeOutcome(_ outcome: LaunchctlOutcome) -> String {
    outcome.stderr.isEmpty ? "launchctl 退出码 \(outcome.exitCode)" : outcome.stderr
  }

  private enum RemovalOutcome {
    case removed
    case removedAfterKill
    case failure(detail: String)
  }

  /// bootout → print 退出码验证（0 已加载 / 113 已移除）；仍加载时用有文档
  /// 的 `launchctl kill SIGTERM` 后备再验证；绝不升级为进程名匹配。
  private func removeJob(_ label: String) async -> RemovalOutcome {
    let outcome = launchctl.bootout(label: label)
    switch outcome.exitCode {
    case 0:
      break
    case 3, 113:
      // print 与 bootout 之间自行退出：意图已达成，不视为失败。
      // 实弹验证（docs/research/legacy-handoff-bootout-live-fire.md）：
      // 未加载 label 的 bootout 退出码为 3（No such process），print 为 113。
      return .removed
    default:
      return .failure(detail: Self.describeOutcome(outcome))
    }
    if await isLabelAbsent(label) {
      RuntimeLog.emit(.legacyHandoffLabelRemoved(label: label))
      return .removed
    }
    _ = launchctl.kill(label: label, signal: SIGTERM)
    if await isLabelAbsent(label) {
      RuntimeLog.emit(.legacyHandoffLabelRemoved(label: label))
      return .removedAfterKill
    }
    return .failure(detail: "bootout 后 launchctl print 仍报告该服务已加载")
  }

  private func isLabelAbsent(_ label: String) async -> Bool {
    for attempt in 0..<removalVerifyAttempts {
      if attempt > 0 {
        try? await Task.sleep(nanoseconds: removalVerifyIntervalNanoseconds)
      }
      if launchctl.serviceState(label: label) == .notLoaded { return true }
    }
    return false
  }

  /// 对三个 Legacy 端口做无复用选项的 bind 探测，限时轮询直到全部空闲；
  /// 探测地址是 2.0 将绑定自己的回环地址——Legacy 在非回环地址上的监听与
  /// 2.0 回环绑定不冲突，不构成门禁失败。
  private func confirmPortsReleased(_ ports: LegacyListenPorts) async throws -> [Int] {
    let targetPorts = [ports.socksPort, ports.httpPort, ports.pacPort]
    for attempt in 0..<portPollAttempts {
      if attempt > 0 {
        try? await Task.sleep(nanoseconds: portPollIntervalNanoseconds)
      }
      if occupiedDescriptions(ports).isEmpty {
        RuntimeLog.emit(
          .legacyHandoffPortsConfirmed(
            portList: targetPorts.map(String.init).joined(separator: "/")))
        return targetPorts
      }
    }
    let occupied = occupiedDescriptions(ports)
    RuntimeLog.emit(.legacyHandoffPortsNotReleased(detail: occupied.joined(separator: "、")))
    throw LegacyHandoffError.portsNotReleased(occupied: occupied)
  }

  /// 每端口恰好探测一次：占用给「端口（进程名）」，探测自身失败给
  /// 「端口（无法判定：…）」——无法判定不冒充空闲。
  private func occupiedDescriptions(_ ports: LegacyListenPorts) -> [String] {
    [ports.socksPort, ports.httpPort, ports.pacPort].compactMap { port in
      switch occupancyProbe.occupancy(port: port, bindAddress: "127.0.0.1") {
      case .free:
        return nil
      case .occupied(let occupier):
        guard let occupier, !occupier.isEmpty else { return String(port) }
        return "\(port)（\(occupier)）"
      case .unknown(let detail):
        return "\(port)（无法判定：\(detail)）"
      }
    }
  }
}
