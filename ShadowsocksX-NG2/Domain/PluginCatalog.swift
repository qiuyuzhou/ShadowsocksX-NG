import Combine
import Foundation

/// Owns mapping intent, publication and asynchronous post-commit work.
/// File availability is captured anew for each derivation, not cached for the session.
final class PluginCatalog: ObservableObject, PluginExecutableResolving {
  enum Change {
    case add(program: String, path: String)
    case update(program: String, path: String)
    case remove(program: String)
    case rename(program: String, newProgram: String, path: String)
  }

  private struct State {
    var mappings: [String: String]
    var generation = 0
    var unreadable: Bool
  }

  private let lock = NSLock()
  private var state: State
  private let store: any PluginMappingStoring
  private let managed: BundleManagedPluginProvider
  private let inspector: any PluginInspecting
  @MainActor @Published private(set) var securityFacts: [String: PluginSecurityFacts] = [:]
  @MainActor private var inspectionTasks: [String: Task<Void, Never>] = [:]
  let didCommit = PassthroughSubject<Int, Never>()
  @MainActor private var invalidateRuntime: (() -> Void)?
  @MainActor private var revalidate: (() -> Void)?
  @MainActor private var converge: (() async -> Void)?

  /// Composition-only wiring. UI submits mapping intent rather than scheduling effects.
  @MainActor
  func connect(
    invalidateRuntime: @escaping () -> Void,
    revalidate: @escaping () -> Void,
    converge: @escaping () async -> Void
  ) {
    self.invalidateRuntime = invalidateRuntime
    self.revalidate = revalidate
    self.converge = converge
  }

  init(
    store: any PluginMappingStoring = PluginMappingFileStore(),
    managed: BundleManagedPluginProvider = BundleManagedPluginProvider(),
    inspector: any PluginInspecting = MacOSPluginInspection()
  ) {
    self.store = store
    self.managed = managed
    self.inspector = inspector
    do {
      state = State(mappings: try store.load(), unreadable: false)
    } catch {
      state = State(mappings: [:], unreadable: true)
    }
  }

  func catalogSnapshot() -> PluginCatalogSnapshot {
    let captured = lock.withLock { state }
    return PluginCatalogSnapshot(
      mappings: captured.mappings, managed: managed, generation: captured.generation,
      mappingsUnreadable: captured.unreadable)
  }

  func executablePath(forProgram program: String) -> String? {
    catalogSnapshot().executablePath(forProgram: program)
  }

  var userMappings: [String: String] { lock.withLock { state.mappings } }

  @MainActor
  func commit(_ changes: [Change]) throws {
    let captured = lock.withLock { state }
    guard !captured.unreadable else { throw PluginMappingError.unreadable }
    var proposed = captured.mappings
    for change in changes {
      switch change {
      case .add(let program, let path):
        let name = try validatedName(program)
        guard proposed[name] == nil else { throw PluginMappingError.nameExists }
        proposed[name] = try validatedPath(path)
      case .update(let program, let path):
        guard proposed[program] != nil else { throw PluginMappingError.nameMissing }
        proposed[program] = try validatedPath(path)
      case .remove(let program):
        guard proposed.removeValue(forKey: program) != nil else {
          throw PluginMappingError.nameMissing
        }
      case .rename(let program, let newProgram, let path):
        try rename(program, newProgram: newProgram, path: path, mappings: &proposed)
      }
    }
    guard proposed != captured.mappings else { return }
    try publishAfterSaving(proposed)
  }

  private func rename(
    _ program: String, newProgram: String, path: String, mappings: inout [String: String]
  ) throws {
    let name = try validatedName(newProgram)
    guard mappings[program] != nil else { throw PluginMappingError.nameMissing }
    guard name == program || mappings[name] == nil else { throw PluginMappingError.nameExists }
    let path = try validatedPath(path)
    mappings.removeValue(forKey: program)
    mappings[name] = path
  }

  /// Explicit repair; a corrupt store never silently becomes an empty override set.
  @MainActor
  func replaceMappings(_ mappings: [String: String]) throws {
    var proposed: [String: String] = [:]
    for (program, path) in mappings {
      let name = try validatedName(program)
      guard proposed[name] == nil else { throw PluginMappingError.nameExists }
      proposed[name] = try validatedPath(path)
    }
    try publishAfterSaving(proposed)
  }

  @MainActor
  private func publishAfterSaving(_ proposed: [String: String]) throws {
    try store.save(proposed)
    objectWillChange.send()
    let generation = lock.withLock {
      state.mappings = proposed
      state.unreadable = false
      state.generation += 1
      return state.generation
    }
    invalidateRuntime?()
    revalidate?()
    didCommit.send(generation)
    refreshSecurityFacts()
    if let converge {
      Task { @MainActor [weak self] in
        guard let self, self.catalogSnapshot().generation == generation else { return }
        await converge()
      }
    }
  }

  /// Explicit refresh also serves activation and startup failure diagnostics.
  @discardableResult
  @MainActor
  func refreshSecurityFacts() -> Task<Void, Never> {
    for task in inspectionTasks.values { task.cancel() }
    inspectionTasks.removeAll()
    securityFacts.removeAll()
    let snapshot = catalogSnapshot()
    for entry in snapshot.entries where entry.source == .user {
      guard let path = entry.path, let identity = PluginFileIdentity(path: path) else { continue }
      let inspector = inspector
      inspectionTasks[entry.program] = Task { @MainActor [weak self] in
        guard !Task.isCancelled else { return }
        let facts = await inspector.inspect(URL(fileURLWithPath: path))
        guard let self, !Task.isCancelled,
          self.catalogSnapshot().generation == snapshot.generation,
          self.catalogSnapshot().entry(for: entry.program)?.path == path,
          PluginFileIdentity(path: path) == identity
        else { return }
        self.securityFacts[entry.program] = facts
        self.inspectionTasks.removeValue(forKey: entry.program)
      }
    }
    let tasks = Array(inspectionTasks.values)
    return Task { @MainActor in
      for task in tasks { await task.value }
    }
  }

  private func validatedName(_ program: String) throws -> String {
    let name = program.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !name.isEmpty, !name.contains("\0") else { throw PluginMappingError.invalidName }
    return name
  }

  private func validatedPath(_ path: String) throws -> String {
    guard path.hasPrefix("/"), !path.contains("\0") else { throw PluginMappingError.invalidPath }
    var isDirectory: ObjCBool = false
    guard managed.fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
      !isDirectory.boolValue, managed.fileManager.isExecutableFile(atPath: path)
    else { throw PluginMappingError.unavailableFile }
    return path
  }
}
