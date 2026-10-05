import Darwin
import Foundation

/// One derivation uses captured executable facts, never a live mutable mapping.
struct PluginCatalogSnapshot: PluginExecutableResolving, Equatable, Sendable {
  enum Source: String, Codable, Sendable {
    case managed
    case user
    case unknown
  }

  enum Availability: Equatable, Sendable {
    case available
    case missing
    case notExecutable
    case unreadable
  }

  struct Entry: Equatable, Sendable {
    let program: String
    let path: String?
    let source: Source
    let availability: Availability
    let managedInfo: ManagedPluginInfo?
  }

  let entries: [Entry]
  let generation: Int
  let mappingsUnreadable: Bool

  init(
    mappings: [String: String],
    managed: BundleManagedPluginProvider = BundleManagedPluginProvider(),
    generation: Int = 0,
    mappingsUnreadable: Bool = false
  ) {
    let programs = Set(ManagedPluginCatalog.plugins.map(\.program)).union(mappings.keys).sorted()
    self.entries = programs.map { program in
      let info = ManagedPluginCatalog.info(forProgram: program)
      let source: Source =
        mappingsUnreadable ? .unknown : (mappings[program] == nil ? .managed : .user)
      let path =
        mappings[program]
        ?? managed.bundleURL
        .appendingPathComponent("Contents/Helpers/Plugins").appendingPathComponent(program).path
      let availability: Availability
      do {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        let attributes = try managed.fileManager.attributesOfItem(atPath: target)
        if attributes[.type] as? FileAttributeType == .typeSymbolicLink {
          // Foundation leaves broken or unresolvable links unchanged. stat follows
          // the target and preserves the distinction between absence and read failure.
          var facts = stat()
          if stat(path, &facts) != 0 {
            availability = errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
          } else {
            availability =
              (facts.st_mode & S_IFMT) == S_IFDIR
                || !managed.fileManager.isExecutableFile(atPath: path) ? .notExecutable : .available
          }
        } else if attributes[.type] as? FileAttributeType == .typeDirectory
          || !managed.fileManager.isExecutableFile(atPath: path)
        {
          availability = .notExecutable
        } else {
          availability = .available
        }
      } catch {
        let failure = error as NSError
        availability =
          failure.domain == NSCocoaErrorDomain
            && failure.code == NSFileReadNoSuchFileError ? .missing : .unreadable
      }
      return Entry(
        program: program, path: path, source: source,
        availability: mappingsUnreadable ? .unreadable : availability,
        managedInfo: source == .managed ? info : nil)
    }
    self.generation = generation
    self.mappingsUnreadable = mappingsUnreadable
  }

  init(entries: [Entry], generation: Int = 0, mappingsUnreadable: Bool = false) {
    self.entries = entries
    self.generation = generation
    self.mappingsUnreadable = mappingsUnreadable
  }

  func entry(for program: String) -> Entry? {
    entries.first { $0.program == program }
  }

  func executablePath(forProgram program: String) -> String? {
    guard !mappingsUnreadable, let entry = entry(for: program),
      entry.availability == .available
    else { return nil }
    return entry.path
  }

  func catalogSnapshot() -> PluginCatalogSnapshot { self }
}
