import Combine
import Foundation

struct PluginEditorSession: Identifiable {
  let id = UUID()
  /// nil only for a new plugin; fixed names cannot be changed by editing.
  let program: String?
  let isEditing: Bool
  let initialPath: String
}

@MainActor
final class PluginManagementModel: ObservableObject {
  let catalog: PluginCatalog
  @Published private(set) var snapshot: PluginCatalogSnapshot
  private var subscription: AnyCancellable?

  init(catalog: PluginCatalog) {
    self.catalog = catalog
    snapshot = catalog.catalogSnapshot()
    subscription = catalog.didCommit.sink { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        self.snapshot = self.catalog.catalogSnapshot()
      }
    }
  }

  func beginAdding() -> PluginEditorSession {
    PluginEditorSession(program: nil, isEditing: false, initialPath: "")
  }

  func beginEditing(_ program: String) -> PluginEditorSession? {
    guard !snapshot.mappingsUnreadable, let path = catalog.userMappings[program] else { return nil }
    return PluginEditorSession(program: program, isEditing: true, initialPath: path)
  }

  func beginOverriding(_ program: String) -> PluginEditorSession? {
    guard !snapshot.mappingsUnreadable, catalog.userMappings[program] == nil,
      ManagedPluginCatalog.info(forProgram: program) != nil
    else { return nil }
    return PluginEditorSession(program: program, isEditing: false, initialPath: "")
  }

  func nameIssue(_ name: String, session: PluginEditorSession) -> PluginMappingError? {
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    if name.isEmpty || name.contains("\0") { return .invalidName }
    if let fixed = session.program, fixed != name { return .invalidName }
    if !session.isEditing && catalog.userMappings[name] != nil { return .nameExists }
    return nil
  }

  func pathIssue(_ path: String) -> PluginMappingError? {
    path.hasPrefix("/") && !path.contains("\0") ? nil : .invalidPath
  }

  func save(_ session: PluginEditorSession, name: String, path: String) throws {
    if let issue = nameIssue(name, session: session) { throw issue }
    if let issue = pathIssue(path) { throw issue }
    let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
    try catalog.commit([
      session.isEditing ? .update(program: name, path: path) : .add(program: name, path: path)
    ])
    refresh()
  }

  func remove(_ program: String) throws {
    try catalog.commit([.remove(program: program)])
    refresh()
  }

  func retryReading() throws {
    try catalog.retryReadingMappings()
    refresh()
  }

  func refresh() {
    snapshot = catalog.catalogSnapshot()
    catalog.refreshSecurityFacts()
  }
}
