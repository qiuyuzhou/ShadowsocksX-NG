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

  init() {
    let dependencies = ApplicationDependencies.make()
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
    _proxyController = StateObject(wrappedValue: controller)
    let loginController = LaunchAtLoginController(service: dependencies.loginService)
    _loginController = StateObject(wrappedValue: loginController)
    // 组合根（issue #40/#41/#49）：目录提交协调器与全部生产运行时适配器只在
    // 此接线一次，各 scene 不再重复设置提交回调；目录工作流的实现依赖经
    // CatalogWorkflowDependencies 显式装配（workflow 不自行创建生产默认实现）；
    // Legacy 导入后的 2.0 运行时边界同为一次性注入。
    let coordinator = CatalogCommitCoordinator(
      fileStore: dependencies.catalogFileStore,
      runtime: ProxyRuntimeSyncAdapter(controller: controller),
      bootstrap: catalogBootstrap)
    let catalogWorkflow = CatalogWorkflow(
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
    _catalogWorkflow = StateObject(wrappedValue: catalogWorkflow)
    // 代理控制工作流 module（issue #47）：状态菜单等 UI 表面的唯一代理控制
    // seam，组合根接线一次。生产 runtime adapter 包装既有控制器（不复制运行
    // 时语义）；目录目标事实经窄缝从目录工作流读取。
    _proxyControl = StateObject(
      wrappedValue: ProxyControlWorkflow(
        runtime: ControllerProxyRuntimeAdapter(controller: controller),
        targetFacts: catalogWorkflow))
    // 设置工作流 module（Candidate 02）：设置窗口的唯一 seam，组合根接线一次；
    // 写入侧经窄缝 SettingsCommitting（issue #44），运行时控制器薄扩展即生产实现。
    _settingsWorkflow = StateObject(wrappedValue: SettingsWorkflow(committing: controller))
    // 诊断工作流 module（issue #43）：诊断区唯一 seam，组合根接线一次；共享
    // 实例供诊断侧栏与详情共同使用。
    _diagnosticsWorkflow = StateObject(
      wrappedValue: DiagnosticsWorkflow(
        runtimeFacts: controller,
        catalogFacts: { catalogWorkflow.diagnosticCatalogFacts }))
    // GUI 事件接入内存环形缓冲（spec #21 D5，issue #34）：主窗口日志查看器与
    // 诊断导出的来源；wrapper 侧不注册，仍走 stderr → agent.log 收敛。
    RuntimeLog.setSink(RuntimeEventStore.shared)
  }

  var body: some Scene {
    MenuBarExtra("ShadowsocksX-NG 2.0", systemImage: "network") {
      ProxyStatusMenu(control: proxyControl, catalogWorkflow: catalogWorkflow)
        .task {
          guard !ApplicationDependencies.isUnitTesting else { return }
          await proxyControl.resyncOnLaunch()
        }
    }
    .menuBarExtraStyle(.menu)

    Window("ShadowsocksX-NG 2.0", id: "main") {
      MainWindowView(
        workflow: catalogWorkflow, proxyController: proxyController,
        diagnostics: diagnosticsWorkflow)
    }
    .defaultLaunchBehavior(
      catalogWorkflow.legacyImportState.shouldOffer ? .automatic : .suppressed)

    // 菜单栏 app 没有可依赖的常规应用菜单；设置窗口必须有显式 scene ID，
    // 由状态菜单通过 openWindow(id:) 打开。
    Window("设置", id: "settings") {
      SettingsView(
        workflow: settingsWorkflow,
        loginController: loginController
      )
      .frame(width: 640, height: 760)
    }
    .defaultLaunchBehavior(.suppressed)
  }
}

/// The test host still loads the app executable because this target is a macOS
/// SwiftUI application. Its bootstrap must nevertheless be hermetic: starting
/// XCTest must not read the user's catalog, settings, activation state, Legacy
/// defaults, login-item registration, runtime files, or production Keychain.
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
    let settingsStore = ProxySettingsFileStore(credentials: credentials)
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
      loginService: SMAppLaunchAtLoginService())
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
      legacyListenFileURL: directory.appendingPathComponent("listen-settings.json"),
      credentials: credentials)
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
      loginService: NoopLaunchAtLoginService())
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
