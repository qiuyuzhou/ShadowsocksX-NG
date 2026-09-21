import Foundation
import ServiceManagement
import SwiftUI

enum LoginItemStatus: Equatable, Sendable {
  case notRegistered
  case registered
  case requiresApproval
  case notFound
}

protocol LaunchAtLoginControlling {
  var status: LoginItemStatus { get }
  func register() throws
  func unregister() throws
}

struct SMAppLaunchAtLoginService: LaunchAtLoginControlling {
  private let service = SMAppService.mainApp

  var status: LoginItemStatus {
    switch service.status {
    case .notRegistered:
      .notRegistered
    case .enabled:
      .registered
    case .requiresApproval:
      .requiresApproval
    case .notFound:
      .notFound
    @unknown default:
      .notFound
    }
  }

  func register() throws {
    try service.register()
  }

  func unregister() throws {
    try service.unregister()
  }
}

/// Owns the GUI login-item intent independently from the proxy LaunchAgent.
/// The setting is enabled by default; registration is attempted at launch and
/// again whenever the user changes the toggle.
@MainActor
final class LaunchAtLoginController: ObservableObject {
  static let preferenceKey = "launchAtLogin.enabled"

  @Published private(set) var isEnabled: Bool
  @Published private(set) var status: LoginItemStatus
  @Published private(set) var errorMessage: String?

  private let service: LaunchAtLoginControlling
  private let defaults: UserDefaults

  init(
    service: LaunchAtLoginControlling = SMAppLaunchAtLoginService(),
    defaults: UserDefaults = .standard
  ) {
    self.service = service
    self.defaults = defaults
    isEnabled = defaults.object(forKey: Self.preferenceKey) as? Bool ?? true
    status = service.status
  }

  var requiresApproval: Bool { status == .requiresApproval }

  func syncAtLaunch() {
    applyDesiredState()
  }

  func setEnabled(_ enabled: Bool) {
    isEnabled = enabled
    defaults.set(enabled, forKey: Self.preferenceKey)
    applyDesiredState()
  }

  func resetToDefaults() {
    defaults.removeObject(forKey: Self.preferenceKey)
    isEnabled = true
    applyDesiredState()
  }

  private func applyDesiredState() {
    do {
      if isEnabled {
        try service.register()
      } else {
        try service.unregister()
      }
      errorMessage = nil
    } catch {
      errorMessage = String(describing: error)
    }
    status = service.status
  }
}
