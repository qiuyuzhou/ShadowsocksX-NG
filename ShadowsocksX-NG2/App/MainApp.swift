import SwiftUI

@main
struct ShadowsocksXNG2App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var proxyController: ProxyRuntimeController
  @StateObject private var catalogWorkflow: CatalogWorkflow
  @StateObject private var proxyControl: ProxyControlWorkflow
  @StateObject private var loginController: LaunchAtLoginController
  @StateObject private var settingsWorkflow: SettingsWorkflow
  @StateObject private var diagnosticsWorkflow: DiagnosticsWorkflow
  @StateObject private var workspaceRoute: WorkspaceRoute
  private let textClipboard: any TextClipboard
  private let diagnosticReportExporter: any DiagnosticReportExporter
  private let windowOpening: WorkspaceWindowOpeningAdapter

  init() {
    let composition = AppComposition.make()
    _proxyController = StateObject(wrappedValue: composition.controller)
    _catalogWorkflow = StateObject(wrappedValue: composition.catalogWorkflow)
    _proxyControl = StateObject(wrappedValue: composition.proxyControl)
    _loginController = StateObject(wrappedValue: composition.loginController)
    _settingsWorkflow = StateObject(wrappedValue: composition.settingsWorkflow)
    _diagnosticsWorkflow = StateObject(wrappedValue: composition.diagnosticsWorkflow)
    _workspaceRoute = StateObject(wrappedValue: composition.workspaceRoute)
    textClipboard = composition.textClipboard
    diagnosticReportExporter = composition.diagnosticReportExporter
    windowOpening = composition.windowOpening
    // GUI 事件接入内存环形缓冲（spec #21 D5，issue #34）：主窗口日志查看器与
    // 诊断导出的来源；wrapper 侧不注册，仍走 stderr → agent.log 收敛。
    RuntimeLog.setSink(RuntimeEventStore.shared)
  }

  var body: some Scene {
    MenuBarExtra {
      ProxyStatusMenu(
        control: proxyControl,
        catalogWorkflow: catalogWorkflow,
        route: workspaceRoute,
        clipboard: textClipboard,
        windowOpening: windowOpening)
    } label: {
      StatusMenuLabel(
        control: proxyControl,
        route: workspaceRoute,
        windowOpening: windowOpening)
    }
    .menuBarExtraStyle(.menu)
  }
}

/// 状态菜单的标签视图（状态栏图标）。挂载时机与菜单内容视图不同：内容视图
/// 首次点开才创建，而标签在启动时即挂载——所以启动策略（resync + launch
/// intent，含开窗）只能挂在这里，挂在菜单内容上等于从不执行。
private struct StatusMenuLabel: View {
  @ObservedObject var control: ProxyControlWorkflow
  @ObservedObject var route: WorkspaceRoute
  let windowOpening: any WorkspaceWindowOpening

  var body: some View {
    Image(systemName: "network")
      .accessibilityLabel("ShadowsocksX-NG 2.0")
      .task {
        guard !ApplicationDependencies.isUnitTesting else { return }
        // 先开窗再 resync：resync 可能 await launchd 往返，不能挡在开窗前面。
        route.handle(.launch, using: windowOpening)
        await control.resyncOnLaunch()
      }
  }
}

/// 组合根装配：目录提交协调器与全部生产运行时适配器只在此接线一次，各 scene
/// 不再重复设置提交回调；目录工作流的实现依赖经 CatalogWorkflowDependencies
/// 显式装配（workflow 不自行创建生产默认实现）；Legacy 导入后的 2.0 运行时
/// 边界同为一次性注入。主窗口由 AppKit 直控（见 WorkspaceWindowOpeningAdapter
/// 文档）；MainWindowView 值廉价且只捕获工作流对象，其 StateObject 状态与
/// onAppear 副作用在视图首次进入窗口时才发生。
@MainActor
private struct AppComposition {
  let controller: ProxyRuntimeController
  let catalogWorkflow: CatalogWorkflow
  let proxyControl: ProxyControlWorkflow
  let loginController: LaunchAtLoginController
  let settingsWorkflow: SettingsWorkflow
  let diagnosticsWorkflow: DiagnosticsWorkflow
  let workspaceRoute: WorkspaceRoute
  let textClipboard: any TextClipboard
  let diagnosticReportExporter: any DiagnosticReportExporter
  let windowOpening: WorkspaceWindowOpeningAdapter

  static func make() -> AppComposition {
    let dependencies = ApplicationDependencies.make()
    let textClipboard = dependencies.textClipboard
    let diagnosticReportExporter = dependencies.diagnosticReportExporter
    // The catalog document is read exactly once at startup. The coordinator
    // publishes later committed snapshots; the controller receives read-only
    // access to this same in-process source.
    let catalogBootstrap = CatalogCommitCoordinator.bootstrap(
      fileStore: dependencies.catalogFileStore)
    let controller = ProxyRuntimeController(
      catalogSnapshotReader: catalogBootstrap.catalogSnapshotReader,
      activationFileStore: dependencies.activationFileStore,
      runtimeFileStore: dependencies.runtimeFileStore,
      credentials: dependencies.credentials,
      listenRestore: dependencies.listenRestore,
      settingsStore: dependencies.settingsStore,
      settingsRestore: dependencies.settingsRestore,
      agent: dependencies.launchAgent)
    let loginController = LaunchAtLoginController(service: dependencies.loginService)
    let catalogWorkflow = makeCatalogWorkflow(
      dependencies: dependencies,
      controller: controller,
      bootstrap: catalogBootstrap)
    // 代理控制工作流 module（issue #47）：状态菜单等 UI 表面的唯一代理控制
    // seam，组合根接线一次。生产 runtime adapter 包装既有控制器（不复制运行
    // 时语义）；目录目标事实经窄缝从目录工作流读取。
    let proxyControl = ProxyControlWorkflow(
      runtime: ControllerProxyRuntimeAdapter(controller: controller),
      targetFacts: catalogWorkflow)
    // 设置工作流 module（Candidate 02）：设置窗口的唯一 seam，组合根接线一次；
    // 写入侧经窄缝 SettingsCommitting（issue #44），运行时控制器薄扩展即生产实现。
    let settingsWorkflow = SettingsWorkflow(committing: controller)
    // 诊断工作流 module（issue #43）：诊断区唯一 seam，组合根接线一次；共享
    // 实例供诊断侧栏与详情共同使用。
    let diagnosticsWorkflow = DiagnosticsWorkflow(
      runtimeFacts: controller,
      catalogFacts: { catalogWorkflow.diagnosticCatalogFacts })
    let workspaceRoute = WorkspaceRoute()
    let workspaceContent = MainWindowView(
      route: workspaceRoute,
      workflow: catalogWorkflow,
      control: proxyControl,
      proxyController: controller,
      diagnostics: diagnosticsWorkflow,
      settingsWorkflow: settingsWorkflow,
      loginController: loginController,
      clipboard: textClipboard,
      diagnosticReportExporter: diagnosticReportExporter)
    let windowOpening = makeWindowOpening(content: workspaceContent, route: workspaceRoute)
    return AppComposition(
      controller: controller,
      catalogWorkflow: catalogWorkflow,
      proxyControl: proxyControl,
      loginController: loginController,
      settingsWorkflow: settingsWorkflow,
      diagnosticsWorkflow: diagnosticsWorkflow,
      workspaceRoute: workspaceRoute,
      textClipboard: textClipboard,
      diagnosticReportExporter: diagnosticReportExporter,
      windowOpening: windowOpening)
  }

  /// 主窗口开窗器装配：AppKit 直控窗口（见 adapter 文档），窗口标题跟随当前
  /// 分区（首页/服务器/订阅/设置/诊断）——组合根一次性接线，@Published 订阅
  /// 立即发出当前值，开窗前即完成标题缓存。
  private static func makeWindowOpening(
    content: MainWindowView, route: WorkspaceRoute
  ) -> WorkspaceWindowOpeningAdapter {
    let windowOpening = WorkspaceWindowOpeningAdapter(
      makeContentView: { NSHostingView(rootView: content) })
    windowOpening.bindTitle(route.$destination.map(\.label).eraseToAnyPublisher())
    return windowOpening
  }

  /// 目录工作流接线（issue #40/#41/#49）：提交协调器与生产运行时适配器在此
  /// 一次性装配；Legacy 导入后的 2.0 运行时边界同为一次性注入。
  private static func makeCatalogWorkflow(
    dependencies: ApplicationDependencies,
    controller: ProxyRuntimeController,
    bootstrap: CatalogCommitBootstrap
  ) -> CatalogWorkflow {
    let coordinator = CatalogCommitCoordinator(
      fileStore: dependencies.catalogFileStore,
      runtime: ProxyRuntimeSyncAdapter(controller: controller),
      bootstrap: bootstrap)
    return CatalogWorkflow(
      dependencies: CatalogWorkflowDependencies(
        coordinator: coordinator,
        credentials: dependencies.credentials,
        plugins: BundleManagedPluginProvider(),
        subscriptionFetcher: HTTPSSubscriptionFetcher(),
        legacyImportService: dependencies.legacyImportService,
        postLegacyImport: { _ in
          await controller.legacyImportDidCommit()
        },
        activator: controller))
  }
}

/// The test host still loads the app executable because this target is a macOS
/// SwiftUI application. Its bootstrap must nevertheless be hermetic: starting
/// XCTest must not read the user's catalog, settings, activation state, Legacy
/// defaults, login-item registration, runtime files, or production Keychain.
@MainActor
private struct ApplicationDependencies {
  let credentials: CredentialStoring
  let catalogFileStore: CatalogFileStore
  let activationFileStore: ActivationStateFileStore
  let runtimeFileStore: RuntimeFileStore
  let settingsStore: ProxySettingsFileStore
  let settingsRestore: RestoredProxySettings
  let listenRestore: RestoredListenSettings
  let legacyImportService: LegacyImportService
  let launchAgent: LaunchAgentControlling
  let loginService: LaunchAtLoginControlling
  let textClipboard: any TextClipboard
  let diagnosticReportExporter: any DiagnosticReportExporter

  static var isUnitTesting: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestSessionIdentifier"] != nil
  }

  static func make() -> ApplicationDependencies {
    guard isUnitTesting else { return makeProduction() }
    return makeTesting()
  }

  private static func makeProduction() -> ApplicationDependencies {
    let credentials = KeychainCredentialStore()
    let catalogFileStore = CatalogFileStore(fileURL: CatalogFileStore.defaultFileURL())
    let settingsStore = ProxySettingsFileStore()
    let restoredSettings = ProxySettingsFileStore.restored(store: settingsStore)
    return ApplicationDependencies(
      credentials: credentials,
      catalogFileStore: catalogFileStore,
      activationFileStore: ActivationStateFileStore(
        fileURL: ActivationStateFileStore.defaultFileURL()),
      runtimeFileStore: RuntimeFileStore(),
      settingsStore: settingsStore,
      settingsRestore: restoredSettings,
      listenRestore: RestoredListenSettings(
        settings: restoredSettings.settings.listen, unreadableError: nil),
      legacyImportService: LegacyImportService(
        catalogStore: catalogFileStore, credentials: credentials),
      launchAgent: SMAppLaunchAgentService(),
      loginService: SMAppLaunchAtLoginService(),
      textClipboard: AppKitTextClipboard(),
      diagnosticReportExporter: AppKitDiagnosticReportExporter())
  }

  private static func makeTesting() -> ApplicationDependencies {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("ShadowsocksX-NG2-test-host-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    let credentials = EphemeralCredentialStore()
    let catalogFileStore = CatalogFileStore(
      fileURL: directory.appendingPathComponent("catalog.json"))
    let settingsStore = ProxySettingsFileStore(
      fileURL: directory.appendingPathComponent("settings.json"),
      legacyListenFileURL: directory.appendingPathComponent("listen-settings.json"))
    let restoredSettings = ProxySettingsFileStore.restored(store: settingsStore)
    let marker = EphemeralLegacyImportMarkerStore()
    let legacyImportService = LegacyImportService(
      source: EmptyLegacySnapshotProvider(),
      catalogStore: catalogFileStore,
      credentials: credentials,
      marker: marker)

    return ApplicationDependencies(
      credentials: credentials,
      catalogFileStore: catalogFileStore,
      activationFileStore: ActivationStateFileStore(
        fileURL: directory.appendingPathComponent("activation.json")),
      runtimeFileStore: RuntimeFileStore(
        fileURL: directory.appendingPathComponent("sslocal-active.json")),
      settingsStore: settingsStore,
      settingsRestore: restoredSettings,
      listenRestore: RestoredListenSettings(
        settings: restoredSettings.settings.listen, unreadableError: nil),
      legacyImportService: legacyImportService,
      launchAgent: NoopLaunchAgentService(),
      loginService: NoopLaunchAtLoginService(),
      textClipboard: InMemoryTextClipboard(),
      diagnosticReportExporter: InMemoryDiagnosticReportExporter())
  }
}

private final class EphemeralCredentialStore: CredentialStoring {
  private var values: [CredentialReference: String] = [:]
  private let lock = NSLock()

  func save(_ secret: String, for reference: CredentialReference) throws {
    lock.lock()
    defer { lock.unlock() }
    values[reference] = secret
  }

  func secret(for reference: CredentialReference) throws -> String? {
    lock.lock()
    defer { lock.unlock() }
    return values[reference]
  }

  func delete(_ reference: CredentialReference) throws {
    lock.lock()
    defer { lock.unlock() }
    values.removeValue(forKey: reference)
  }
}

private struct EmptyLegacySnapshotProvider: LegacySnapshotProviding {
  func readSnapshot() throws -> LegacySnapshot? { nil }
}

private final class EphemeralLegacyImportMarkerStore: LegacyImportMarkerStoring {
  private var completed = false

  func isCompleted() throws -> Bool { completed }

  func setCompleted(_ completed: Bool) throws {
    self.completed = completed
  }
}

private struct NoopLaunchAgentService: LaunchAgentControlling {
  var status: LaunchAgentStatus { .notRegistered }
  func register() throws {}
  func unregister() throws {}
}

private struct NoopLaunchAtLoginService: LaunchAtLoginControlling {
  var status: LoginItemStatus { .notRegistered }
  func register() throws {}
  func unregister() throws {}
}
