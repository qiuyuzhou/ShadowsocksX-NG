import XCTest

@testable import ShadowsocksX_NG2

final class ServerValidationTests: XCTestCase {
  func testSupportedServerWithOpaquePluginOptionsIsValid() throws {
    let passwordRef = CredentialReference(rawValue: "password")
    let optionsRef = CredentialReference(rawValue: "options")
    let credentials = try ActivationFixture.makeCredentials([
      passwordRef: "password",
      optionsRef: "plugin-option-that-the-app-does-not-parse",
    ])
    let fields = ServerFields(
      address: "203.0.113.7",
      port: 8388,
      encryptionMethod: "aes-256-gcm",
      passwordRef: passwordRef,
      pluginProgram: "v2ray-plugin",
      pluginOptionsRef: optionsRef)

    let validation = ServerValidation.evaluate(
      fields, credentials: credentials, plugins: ActivationFixture.plugins)

    XCTAssertTrue(validation.isValid)
  }

  func testUnsupportedEncryptionMethodIsAnInvalidActivationCandidate() throws {
    let passwordRef = CredentialReference(rawValue: "password")
    let credentials = try ActivationFixture.makeCredentials([passwordRef: "password"])
    let fields = ServerFields(
      address: "203.0.113.7",
      port: 8388,
      encryptionMethod: "future-cipher",
      passwordRef: passwordRef)

    let validation = ServerValidation.evaluate(
      fields, credentials: credentials, plugins: ActivationFixture.plugins)

    XCTAssertEqual(validation.issues, [.unsupportedEncryptionMethod("future-cipher")])
  }

  func testMissingPluginExecutableIsInvalidWithoutInspectingOptions() throws {
    let passwordRef = CredentialReference(rawValue: "password")
    let optionsRef = CredentialReference(rawValue: "options")
    let credentials = try ActivationFixture.makeCredentials([
      passwordRef: "password",
      optionsRef: "opaque-options",
    ])
    let fields = ServerFields(
      address: "203.0.113.7",
      port: 8388,
      encryptionMethod: "aes-256-gcm",
      passwordRef: passwordRef,
      pluginProgram: "unknown-plugin",
      pluginOptionsRef: optionsRef)

    let validation = ServerValidation.evaluate(
      fields, credentials: credentials, plugins: NoManagedPluginProvider())

    XCTAssertEqual(
      validation.issues,
      [.pluginNotProvided(program: "unknown-plugin")])
  }

  func testMissingPasswordIsInvalid() throws {
    let passwordRef = CredentialReference(rawValue: "password")
    let credentials = try ActivationFixture.makeCredentials([passwordRef: ""])
    let fields = ActivationFixture.plainFields(remark: "server", passwordRef: passwordRef)

    let validation = ServerValidation.evaluate(
      fields, credentials: credentials, plugins: ActivationFixture.plugins)

    XCTAssertEqual(validation.issues, [.credentialUnresolved(passwordRef)])
  }
}
