import Foundation
import Testing

@testable import ShadowsocksX_NG2

@MainActor
struct PluginManagementTests {
  @Test func editingKeepsNameAndUpdatesExecutable() throws {
    let fixture = try ManagementFixture()
    defer { fixture.cleanUp() }
    let model = PluginManagementModel(catalog: fixture.catalog)
    let add = model.beginAdding()
    try model.save(add, name: "custom", path: fixture.first.path)
    let edit = try #require(model.beginEditing("custom"))
    #expect(edit.program == "custom")
    #expect(edit.initialPath == fixture.first.path)
    #expect(throws: PluginMappingError.invalidName) {
      try model.save(edit, name: "renamed", path: fixture.second.path)
    }
    #expect(fixture.catalog.userMappings["custom"] == fixture.first.path)
    try model.save(edit, name: "custom", path: fixture.second.path)
    #expect(model.snapshot.entry(for: "custom")?.path == fixture.second.path)
    #expect(model.snapshot.entry(for: "renamed") == nil)
  }

  @Test func overrideCanBeEditedAndRestoredWithoutDeletingManagedEntry() throws {
    let fixture = try ManagementFixture()
    defer { fixture.cleanUp() }
    let model = PluginManagementModel(catalog: fixture.catalog)
    let override = try #require(model.beginOverriding("v2ray-plugin"))
    #expect(override.program == "v2ray-plugin")
    #expect(override.initialPath.isEmpty)
    #expect(!override.isEditing)
    try model.save(override, name: "v2ray-plugin", path: fixture.first.path)
    #expect(model.snapshot.entry(for: "v2ray-plugin")?.source == .user)
    #expect(model.beginOverriding("v2ray-plugin") == nil)
    let edit = try #require(model.beginEditing("v2ray-plugin"))
    try model.save(edit, name: "v2ray-plugin", path: fixture.second.path)
    #expect(model.snapshot.entry(for: "v2ray-plugin")?.path == fixture.second.path)
    try model.remove("v2ray-plugin")
    #expect(model.snapshot.entry(for: "v2ray-plugin")?.source == .managed)
    #expect(model.beginEditing("v2ray-plugin") == nil)
    #expect(model.beginOverriding("v2ray-plugin") != nil)
  }

  @Test func unreadableMappingsBlockChangesUntilSuccessfulReadRetry() throws {
    let fixture = try ManagementFixture(corrupt: true)
    defer { fixture.cleanUp() }
    let model = PluginManagementModel(catalog: fixture.catalog)
    #expect(model.snapshot.mappingsUnreadable)
    #expect(model.beginOverriding("v2ray-plugin") == nil)
    #expect(throws: PluginMappingError.unreadable) {
      try model.save(model.beginAdding(), name: "custom", path: fixture.first.path)
    }
    #expect(throws: PluginMappingError.unreadable) { try model.retryReading() }
    #expect(model.snapshot.mappingsUnreadable)
    try fixture.store.save(["custom": fixture.first.path])
    let repairedBytes = try Data(contentsOf: fixture.store.fileURL)
    try model.retryReading()
    #expect(!model.snapshot.mappingsUnreadable)
    #expect(model.snapshot.entry(for: "custom")?.path == fixture.first.path)
    #expect(try Data(contentsOf: fixture.store.fileURL) == repairedBytes)
    #expect(model.beginEditing("custom") != nil)
  }

  @Test func failedSavePreservesMappingAndAllowsSameEditorToRetry() throws {
    let fixture = try ManagementFixture()
    defer { fixture.cleanUp() }
    let model = PluginManagementModel(catalog: fixture.catalog)
    try model.save(model.beginAdding(), name: "custom", path: fixture.first.path)
    let edit = try #require(model.beginEditing("custom"))
    let config = fixture.store.fileURL.deletingLastPathComponent()
    let backup = fixture.root.appendingPathComponent("backup")
    try FileManager.default.moveItem(at: config, to: backup)
    try Data("blocking file".utf8).write(to: config)
    #expect(throws: (any Error).self) {
      try model.save(edit, name: "custom", path: fixture.second.path)
    }
    #expect(model.snapshot.entry(for: "custom")?.path == fixture.first.path)
    #expect(model.beginEditing("custom")?.initialPath == fixture.first.path)
    try FileManager.default.removeItem(at: config)
    try FileManager.default.moveItem(at: backup, to: config)
    try model.save(edit, name: "custom", path: fixture.second.path)
    #expect(model.snapshot.entry(for: "custom")?.path == fixture.second.path)
  }

  @Test func unavailableFilesAndDuplicateNamesAreRejectedAndRemovalKeepsOtherMappings() throws {
    let fixture = try ManagementFixture()
    defer { fixture.cleanUp() }
    let model = PluginManagementModel(catalog: fixture.catalog)
    let add = model.beginAdding()
    #expect(add.program == nil)
    #expect(add.initialPath.isEmpty)
    #expect(model.nameIssue("", session: add) == .invalidName)
    #expect(model.pathIssue("relative") == .invalidPath)
    try model.save(add, name: "custom", path: fixture.first.path)
    #expect(model.nameIssue("custom", session: model.beginAdding()) == .nameExists)
    #expect(throws: PluginMappingError.nameExists) {
      try model.save(model.beginAdding(), name: "custom", path: fixture.second.path)
    }
    #expect(throws: PluginMappingError.unavailableFile) {
      try model.save(
        model.beginAdding(), name: "missing",
        path: fixture.root.appendingPathComponent("missing").path)
    }
    try model.save(model.beginAdding(), name: "other", path: fixture.second.path)
    try model.remove("custom")
    #expect(model.snapshot.entry(for: "custom") == nil)
    #expect(model.snapshot.entry(for: "other")?.path == fixture.second.path)
    try FileManager.default.removeItem(at: fixture.second)
    model.refresh()
    #expect(model.snapshot.entry(for: "other")?.availability == .missing)
    #expect(model.beginEditing("other")?.initialPath == fixture.second.path)
  }

}

private struct ManagementInspector: PluginInspecting {
  func inspect(_ executable: URL) async -> PluginSecurityFacts {
    PluginSecurityFacts(quarantine: .absent, signature: .notApplicable, policy: .notApplicable)
  }
}

@MainActor
private struct ManagementFixture {
  let root: URL
  let first: URL
  let second: URL
  let store: PluginMappingFileStore
  let catalog: PluginCatalog

  init(corrupt: Bool = false) throws {
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    first = root.appendingPathComponent("first")
    second = root.appendingPathComponent("second")
    store = PluginMappingFileStore(fileURL: root.appendingPathComponent("config/plugins.json"))
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
      at: store.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    for binary in [first, second] {
      try Data("#!/bin/sh\n".utf8).write(to: binary)
      try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)
    }
    if corrupt { try Data("broken".utf8).write(to: store.fileURL) }
    catalog = PluginCatalog(store: store, inspector: ManagementInspector())
  }

  func cleanUp() { try? FileManager.default.removeItem(at: root) }
}
