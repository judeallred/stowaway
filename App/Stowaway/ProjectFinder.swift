import Foundation
import StowawayCore

/// Finds where the user keeps their projects, before they've granted anything, by asking
/// Spotlight for project manifests. Spotlight answers the sandboxed app with paths across the
/// home folder (it can't read the files, and doesn't need to): enough to suggest "~/code" in
/// onboarding instead of making the user hunt for it.
@MainActor
enum ProjectFinder {
  /// A folder that holds projects, and how many.
  struct Suggestion: Hashable {
    let folder: URL
    let projects: Int
  }

  private static let manifests = [
    "package.json", "Cargo.toml", "Package.swift", "go.mod", "pyproject.toml", "build.gradle",
    "build.gradle.kts", "Gemfile", "pubspec.yaml", "composer.json", "pom.xml",
  ]

  /// Folders directly in the home folder (or in Documents or Desktop) that hold projects, most
  /// projects first. Empty if Spotlight is off or finds nothing within a few seconds.
  static func suggestions() async -> [Suggestion] {
    let query = NSMetadataQuery()
    query.predicate = NSCompoundPredicate(
      orPredicateWithSubpredicates: manifests.map { NSPredicate(format: "kMDItemFSName == %@", $0) }
    )
    query.searchScopes = [NSMetadataQueryUserHomeScope]
    let paths = await withCheckedContinuation { (done: CheckedContinuation<[String], Never>) in
      let gather = Gather(query: query, done: done)
      gather.observer = NotificationCenter.default.addObserver(
        forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main
      ) { _ in MainActor.assumeIsolated { gather.finish() } }
      guard query.start() else { return gather.finish() }
      Task {
        try? await Task.sleep(for: .seconds(8))
        gather.finish()
      }
    }
    return rank(paths, home: realHomeDirectory.path)
  }

  /// Groups manifest paths by the top-level folder that holds them, skipping hidden folders,
  /// Library, and packages inside node_modules.
  nonisolated static func rank(_ paths: [String], home: String) -> [Suggestion] {
    var projects = Set<String>()
    for path in paths where path.hasPrefix(home + "/") {
      let parts = path.dropFirst(home.count + 1).split(separator: "/").dropLast()
      guard !parts.isEmpty, !parts.contains("node_modules"),
        !parts.contains(where: { $0.hasPrefix(".") }), parts.first != "Library"
      else { continue }
      projects.insert(parts.joined(separator: "/"))
    }
    var counts: [String: Int] = [:]
    for project in projects {
      let parts = project.split(separator: "/")
      // A project directly in the home folder suggests itself; otherwise its top folder does
      // (one deeper for Documents and Desktop, which hold too much else to suggest whole).
      let depth = ["Documents", "Desktop"].contains(String(parts[0])) ? 2 : 1
      counts[parts.prefix(depth).joined(separator: "/"), default: 0] += 1
    }
    // A folder that's a project itself (a repository, or a monorepo) is one project, however
    // many manifests it holds. The sandbox allows checking that `.git` exists, not reading it.
    for folder in counts.keys
    where projects.contains(folder)
      || FileManager.default.fileExists(atPath: "\(home)/\(folder)/.git")
    {
      counts[folder] = 1
    }
    return
      counts
      .filter { $0.value >= 2 || counts.count == 1 }
      .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
      .map {
        Suggestion(
          folder: URL(fileURLWithPath: home).appendingPathComponent($0.key), projects: $0.value)
      }
  }

  /// Collects a query's results once, when it finishes gathering or times out.
  @MainActor private final class Gather {
    let query: NSMetadataQuery
    var done: CheckedContinuation<[String], Never>?
    var observer: NSObjectProtocol?

    init(query: NSMetadataQuery, done: CheckedContinuation<[String], Never>) {
      self.query = query
      self.done = done
    }

    func finish() {
      guard let done else { return }
      self.done = nil
      query.disableUpdates()
      let paths = (0..<query.resultCount).compactMap {
        (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey)
          as? String
      }
      query.stop()
      if let observer { NotificationCenter.default.removeObserver(observer) }
      done.resume(returning: paths)
    }
  }
}
