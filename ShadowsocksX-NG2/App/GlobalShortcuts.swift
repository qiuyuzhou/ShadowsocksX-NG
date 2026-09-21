import KeyboardShortcuts

/// 全局快捷键（spec #21 D11，issue #31）：开关代理、切换模式两个系统级热键。
/// 快捷键不迁移 Legacy（D12），用 2.0 默认键位（Name.initialShortcut：用户
/// 未改过即生效）；编辑 UI 在设置区（#33）。
extension KeyboardShortcuts.Name {
  /// ⌃⌥⌘S：开关代理。
  static let toggleProxy = Self(
    "toggleProxy",
    initial: .init(.s, modifiers: [.control, .option, .command]))
  /// ⌃⌥⌘M：在 PAC / 全局 / 手动三个内置模式间循环切换。
  static let cycleProxyMode = Self(
    "cycleProxyMode",
    initial: .init(.m, modifiers: [.control, .option, .command]))
}

enum GlobalShortcuts {
  /// 接线快捷键动作（应用启动时调用一次）。两个动作都与菜单栏同名项走同一
  /// 控制器入口，状态一致由 @Published 事实来源保证；「开关代理」的意图判定
  /// 与菜单开关联用同一 `isOn(state:)` 口径（含启动失败等中间态的「开」判定）。
  @MainActor
  static func wire(controller: ProxyRuntimeController) {
    KeyboardShortcuts.onKeyUp(for: .toggleProxy) {
      Task { @MainActor in
        await controller.setProxyEnabled(!StatusMenuModel.isOn(state: controller.state))
      }
    }
    KeyboardShortcuts.onKeyUp(for: .cycleProxyMode) {
      Task { @MainActor in
        await controller.setProxyMode(
          StatusMenuModel.nextMode(
            after: controller.proxyMode, availableModes: controller.settings.enabledModes))
      }
    }
  }
}
