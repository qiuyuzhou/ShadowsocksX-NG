import XCTest

@testable import ShadowsocksX_NG2

/// Mode restoration and commands share the Domain availability policy without
/// starting a real runtime or touching host proxy settings.
@MainActor
extension ProxyRuntimeControllerTests {
  func testRuntimeFactsProjectControllerStateAtStableSeam() async {
    let controller = makeController(probe: ProxyRuntimeFixture.FakeProbe.reachable())

    XCTAssertEqual(
      controller.runtimeFacts,
      ProxyRuntimeFacts(status: .off, isOn: false))

    await controller.setProxyEnabled(true)

    XCTAssertEqual(
      controller.runtimeFacts,
      ProxyRuntimeFacts(
        status: .activationFailed,
        isOn: false,
        failure: .activation(.noActiveTarget)))
  }

  func testRestoreUsesConfiguredExternalPACWhenItIsAvailable() {
    let url = URL(string: "https://pac.example.test/proxy.pac")!
    var restoredSettings = ProxySettings(externalPACURL: url.absoluteString)
    restoredSettings.preferredMode = .externalPAC

    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsRestore: RestoredProxySettings(settings: restoredSettings, unreadableError: nil),
      proxyMode: nil)

    XCTAssertEqual(controller.proxyMode, .externalPAC(url))
  }

  func testRestoreFallsBackToPACWhenExternalPACIsUnavailable() {
    for url in ["", "ftp://pac.example.test/proxy.pac"] {
      var restoredSettings = ProxySettings(externalPACURL: url)
      restoredSettings.preferredMode = .externalPAC

      let controller = makeController(
        probe: ProxyRuntimeFixture.FakeProbe.reachable(),
        settingsRestore: RestoredProxySettings(settings: restoredSettings, unreadableError: nil),
        proxyMode: nil)

      XCTAssertEqual(controller.proxyMode, .pac, "不可用外部 PAC 应恢复为 PAC：\(url)")
    }
  }

  func testSetProxyModePersistsConfiguredExternalPAC() async {
    let url = URL(string: "https://pac.example.test/proxy.pac")!
    let settingsStore = InMemoryProxySettingsStore()
    let settings = ProxySettings(externalPACURL: url.absoluteString)
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settingsRestore: RestoredProxySettings(settings: settings, unreadableError: nil))

    await controller.setProxyMode(.externalPAC(url))

    XCTAssertEqual(controller.proxyMode, .externalPAC(url))
    XCTAssertEqual(controller.settings.preferredMode, .externalPAC)
    XCTAssertEqual(settingsStore.saved?.preferredMode, .externalPAC)
  }

  func testSetProxyModeIgnoresUnconfiguredExternalPACWithoutSideEffects() async {
    let settingsStore = InMemoryProxySettingsStore()
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(), settingsStore: settingsStore)
    let originalSettings = controller.settings
    let requestedURL = URL(string: "https://pac.example.test/proxy.pac")!

    await controller.setProxyMode(.externalPAC(requestedURL))

    XCTAssertEqual(controller.settings, originalSettings)
    XCTAssertEqual(controller.proxyMode, .pac)
    XCTAssertNil(settingsStore.saved)
    XCTAssertEqual(controller.state, .off)
    XCTAssertTrue(systemProxy.applied.isEmpty)
    XCTAssertEqual(agent.registerCount, 0)
  }

  func testSetProxyModeIgnoresExternalPACWithDifferentConfiguredURL() async {
    let configuredURL = URL(string: "https://configured.example.test/proxy.pac")!
    let requestedURL = URL(string: "https://other.example.test/proxy.pac")!
    let settingsStore = InMemoryProxySettingsStore()
    var configuredSettings = ProxySettings(externalPACURL: configuredURL.absoluteString)
    configuredSettings.preferredMode = .externalPAC
    settingsStore.saved = configuredSettings
    let controller = makeController(
      probe: ProxyRuntimeFixture.FakeProbe.reachable(),
      settingsStore: settingsStore,
      settingsRestore: RestoredProxySettings(settings: configuredSettings, unreadableError: nil),
      proxyMode: nil)

    await controller.setProxyMode(.externalPAC(requestedURL))

    XCTAssertEqual(controller.settings, configuredSettings)
    XCTAssertEqual(controller.proxyMode, .externalPAC(configuredURL))
    XCTAssertEqual(settingsStore.saved, configuredSettings)
    XCTAssertEqual(controller.state, .off)
    XCTAssertTrue(systemProxy.applied.isEmpty)
    XCTAssertEqual(agent.registerCount, 0)
  }
}
