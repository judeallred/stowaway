import Foundation

/// The folders the user granted through an open panel, kept as app-scoped security-scoped
/// bookmarks: the only way a sandboxed Stowaway could keep reaching `~/code` and the drive
/// across launches.
enum Place: String, CaseIterable, Sendable {
  case codeRoot
  case drive

  var title: String {
    switch self {
    case .codeRoot: "Code folder"
    case .drive: "External drive"
    }
  }
}

struct ResolvedPlace: Sendable {
  let url: URL
  let stale: Bool
  /// Whether the bookmark was saved by an earlier launch (proves it survives a relaunch).
  let fromEarlierLaunch: Bool
}

enum Bookmarks {
  private static let launchKey = "launchID"
  /// Identifies this launch, so a bookmark saved by an earlier one can be told apart.
  private static let thisLaunch = UUID().uuidString
  nonisolated(unsafe) private static var previousLaunch: String? = {
    let previous = UserDefaults.standard.string(forKey: launchKey)
    UserDefaults.standard.set(thisLaunch, forKey: launchKey)
    return previous
  }()

  static func save(_ url: URL, as place: Place) throws {
    let data = try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    _ = previousLaunch
    UserDefaults.standard.set(data, forKey: place.rawValue)
    UserDefaults.standard.set(thisLaunch, forKey: place.rawValue + ".launch")
  }

  static func forget(_ place: Place) {
    UserDefaults.standard.removeObject(forKey: place.rawValue)
  }

  /// Resolves and starts accessing the bookmark. Callers balance it with `stopAccessing`.
  static func resolve(_ place: Place) -> Result<ResolvedPlace, any Error>? {
    _ = previousLaunch
    guard let data = UserDefaults.standard.data(forKey: place.rawValue) else { return nil }
    do {
      var stale = false
      let url = try URL(
        resolvingBookmarkData: data, options: .withSecurityScope, relativeTo: nil,
        bookmarkDataIsStale: &stale)
      guard url.startAccessingSecurityScopedResource() else {
        return .failure(ProbeError("startAccessingSecurityScopedResource returned false"))
      }
      let savedBy = UserDefaults.standard.string(forKey: place.rawValue + ".launch")
      return .success(ResolvedPlace(url: url, stale: stale, fromEarlierLaunch: savedBy != thisLaunch))
    } catch {
      return .failure(error)
    }
  }

  static func path(of place: Place) -> String? {
    guard let data = UserDefaults.standard.data(forKey: place.rawValue) else { return nil }
    var stale = false
    return (try? URL(
      resolvingBookmarkData: data, options: [.withSecurityScope, .withoutUI], relativeTo: nil,
      bookmarkDataIsStale: &stale))?.path
  }
}

struct ProbeError: LocalizedError {
  let message: String
  init(_ message: String) { self.message = message }
  var errorDescription: String? { message }
}
