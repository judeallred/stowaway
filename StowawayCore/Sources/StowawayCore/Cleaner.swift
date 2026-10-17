import Foundation

/// Deletes re-creatable folders. Free for everyone; the guard rails are the same as offloading's.
public struct Cleaner: Sendable {
  public init() {}

  /// Why `candidate` mustn't be deleted, or nil if it may.
  public func refusal(_ candidate: Candidate, roots: [String], offloaded: [Entry]) -> String? {
    let path = candidate.url.standardizedFileURL.path
    // A cache folder granted directly counts: cleaning empties it but keeps it.
    let inside = roots.contains {
      path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") || (candidate.kind.isGlobal && path == $0)
    }
    guard inside else {
      return "it isn't inside a folder you've given Stowaway"
    }
    if offloaded.contains(where: {
      path == $0.local || path.hasPrefix($0.local + "/") || $0.local.hasPrefix(path + "/")
    }) {
      return "it's offloaded; bring it back first, or delete it from the offload location"
    }
    guard isRealDirectory(path) else { return "it isn't a folder any more" }
    // Re-check that the folder still is what the scan said it was.
    if let rule = candidate.kind.projectRule, let project = candidate.project {
      guard FileManager.default.fileExists(atPath: project + "/" + rule.manifest),
        URL(fileURLWithPath: path).lastPathComponent == rule.folderName,
        rule.requiredMarker.map({ FileManager.default.fileExists(atPath: path + "/" + $0) }) ?? true
      else { return "it no longer looks like \(candidate.kind.label)" }
    }
    if GitIndex.containsRepository(candidate.url) { return "it contains a git repository" }
    switch GitIndex.tracking(of: candidate.url) {
    case .untracked: return nil
    case .tracked: return "git tracks files in it"
    case .unknown: return "its git repository couldn't be read"
    }
  }

  /// Deletes a project folder outright. For a machine-wide cache, empties it but keeps the folder,
  /// so the permission the user granted for it stays valid.
  @discardableResult
  public func delete(_ candidate: Candidate, roots: [String], offloaded: [Entry]) throws -> Int64 {
    if let refusal = refusal(candidate, roots: roots, offloaded: offloaded) {
      throw StowawayError("Stowaway didn't delete \(candidate.path): \(refusal)")
    }
    let freed = Measure.allocatedSize(candidate.path)
    if candidate.kind.isGlobal {
      for name in try FileManager.default.contentsOfDirectory(atPath: candidate.path) {
        try Copier.remove(candidate.url.appendingPathComponent(name))
      }
    } else {
      try Copier.remove(candidate.url)
    }
    return freed
  }
}
