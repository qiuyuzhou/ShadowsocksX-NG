import Combine
import Foundation

/// 生产运行时 adapter（issue #47）：现有 `ProxyRuntimeController` 的唯一
/// 包装，由应用组合根接线。只把控制器既有能力与观察投影到 workflow 缝上，
/// 不复制状态机、generation、健康门禁与系统代理 ownership 语义。
@MainActor
final class ControllerProxyRuntimeAdapter: ProxyRuntimeAdapting {
  private let controller: ProxyRuntimeController

  init(controller: ProxyRuntimeController) {
    self.controller = controller
  }

  var runtimeFacts: ProxyRuntimeFacts { controller.runtimeFacts }

  var proxyMode: ProxyMode { controller.proxyMode }

  var skippedInvalidServerCount: Int { controller.skippedServers.count }

  var activeTargetID: NodeID? { controller.activeTargetID }

  var httpExportCapability: HTTPExportCapability? {
    HTTPExportCapability(listen: controller.listenSettings)
  }

  /// 控制器的 `objectWillChange` 是 willChange 语义；主队列 hop 落地时被
  /// 发布的新值已可读，workflow 重观察不会读到半程状态。
  var changes: AnyPublisher<Void, Never> {
    controller.objectWillChange
      .map { _ in () }
      .receive(on: DispatchQueue.main)
      .eraseToAnyPublisher()
  }

  func resyncOnLaunch() async {
    await controller.resyncOnLaunch()
  }

  func setProxyEnabled(_ enabled: Bool) async {
    await controller.setProxyEnabled(enabled)
  }

  func setProxyMode(_ mode: ProxyMode) async {
    await controller.setProxyMode(mode)
  }
}

/// HTTP 导出能力的唯一派生点：监听设置 → 可复制导出行。地址取监听范围的
/// 对外地址（回环态 127.0.0.1，主机态为对外公布地址），与 PAC 语义一致。
extension HTTPExportCapability {
  init?(listen: SslocalListenSettings) {
    guard listen.httpProxyEnabled else { return nil }
    let endpoint = "http://\(listen.scope.advertisedAddress):\(listen.httpPort)"
    self.init(copyableLine: "export http_proxy=\(endpoint);export https_proxy=\(endpoint);")
  }
}

/// 目录侧唯一的目标事实出口（窄缝，story 28）：存在性 + 显示名路径摘要；
/// 完整目录树、订阅对象与凭据不出此接口。
extension CatalogWorkflow: ProxyTargetFactsReading {
  func activeTargetFacts(for targetID: NodeID?) -> ProxyActiveTargetFacts? {
    guard let targetID else { return nil }
    return ProxyActiveTargetFacts(id: targetID, pathSummary: tree.pathSummary(for: targetID))
  }
}
