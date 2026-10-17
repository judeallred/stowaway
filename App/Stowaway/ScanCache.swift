import Foundation
import StowawayCore

/// The last scan's folders and sizes, kept in the app's container. At launch the library shows
/// them right away, and a rescan corrects them as it goes instead of counting up from zero.
struct ScanCache: Codable {
  struct Folder: Codable {
    let path: String
    let kind: String
    let project: String?
    let bytes: Int64
    let activity: Date
  }

  var folders: [Folder] = []

  private static var url: URL {
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[
      0]
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    return support.appendingPathComponent("scan-cache.json")
  }

  static func load() -> ScanCache {
    (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode(ScanCache.self, from: $0) }
      ?? ScanCache()
  }

  func save() {
    try? JSONEncoder().encode(self).write(to: Self.url, options: .atomic)
  }

  var candidates: [Candidate] {
    folders.compactMap { folder in
      Kind(rawValue: folder.kind).map {
        Candidate(kind: $0, path: folder.path, project: folder.project)
      }
    }
  }
}
