import SwiftUI

@main
struct ShadowsocksXNG2App: App {
  @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
  @StateObject private var proxyController: ProxyRuntimeController
  @StateObject private var catalogWorkflow: CatalogWorkflow
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
    // 组合根（issue #40/#41）：目录提交协调器与生产运行时适配器只在此接线一次，
    // 各 scene 不再重复设置提交回调；Legacy 导入后的 2.0 运行时边界同为一次性注入。
    let coordinator = CatalogCommitCoordinator(
      fileStore: dependencies.catalogFileStore,
      runtime: ProxyRuntimeSyncAdapter(controller: controller),
      bootstrap: catalogBootstrap)
    let catalogWorkflow = CatalogWorkflow(
      coordinator: coordinator,
      credentials: dependencies.credentials,
      legacyImportService: dependencies.legacyImportService,
      postLegacyImport: { _ in
        await controller.legacyImportDidCommit()
      },
      activator: controller)
    _catalogWorkflow = StateObject(wrappedValue: catalogWorkflow)
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
      ProxyStatusMenu(controller: proxyController, catalogWorkflow: catalogWorkflow)
        .task {
          guard !ApplicationDependencies.isUnitTesting else { return }
          await proxyController.resyncOnLaunch()
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
  let legacyImportService: LegacyImportService?
  let launchAgent: LaunchAgentControlling
  let loginService: LaunchAtLoginControlling

  static var isUnitTesting: Bool {
    let environment = ProcessInfo.processInfo.environment
    return environment["XCTestConfigurationFilePath"] != nil
      || environment["XCTestSessionIdentifier"] != nil
  }

  static func make() -> ApplicationDependencies {
    guard isUnitTesting else {
      let credentials = KeychainCredentialStore()
      let settingsStore = ProxySettingsFileStore(credentials: credentials)
      let restoredSettings = ProxySettingsFileStore.restored(store: settingsStore)
      return ApplicationDependencies(
        credentials: credentials,
        catalogFileStore: CatalogFileStore(fileURL: CatalogFileStore.defaultFileURL()),
        activationFileStore: ActivationStateFileStore(
          fileURL: ActivationStateFileStore.defaultFileURL()),
        runtimeFileStore: RuntimeFileStore(),
        settingsStore: settingsStore,
        settingsRestore: restoredSettings,
        listenRestore: RestoredListenSettings(
          settings: restoredSettings.settings.listen, unreadableError: nil),
        legacyImportService: nil,
        launchAgent: SMAppLaunchAgentService(),
        loginService: SMAppLaunchAtLoginService())
    }

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
