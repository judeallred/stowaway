import Foundation
import StowawayCore

/// A prefilled GitHub issue. Nothing is sent until the user reviews and submits it in their
/// browser, and it carries no paths or folder names: only versions and counts.
enum BugReport {
  @MainActor
  static func url(model: AppModel) -> URL {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let kinds = Dictionary(grouping: model.rows, by: \.kind).map {
      "\($0.key.rawValue): \($0.value.count)"
    }.sorted()
    let body = """
      **What happened?**


      **What did you expect?**


      ---
      Stowaway \(Bundle.main.versionString) on macOS \(os)
      Drive chosen: \(model.drivePath == nil ? "no" : "yes"), connected: \(model.driveConnected ? "yes" : "no")
      Folders found: \(kinds.joined(separator: ", "))
      """
    var components = URLComponents(url: Links.issues, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "body", value: body)]
    return components?.url ?? Links.issues
  }
}
