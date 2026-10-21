import Foundation
import StowawayCore

/// A prefilled GitHub issue. Nothing is sent until the user reviews and submits it in their
/// browser. It carries versions, counts, and the last few failures, whose folder paths are
/// shortened to `~/…`; the report asks the user to remove names they'd rather not share, since
/// the issue is public.
enum BugReport {
  /// How many recent failures the app keeps, and the report includes.
  static let failuresKept = 10

  @MainActor
  static func url(model: AppModel) -> URL {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let kinds = Dictionary(grouping: model.rows, by: \.kind).map {
      "\($0.key.rawValue): \($0.value.count)"
    }.sorted()
    var body = """
      **What happened?**


      **What did you expect?**


      ---
      Stowaway \(Bundle.main.versionString) on macOS \(os)
      Drive chosen: \(model.drivePath == nil ? "no" : "yes"), connected: \(model.driveConnected ? "yes" : "no")
      Folders found: \(kinds.joined(separator: ", "))
      """
    if !model.recentFailures.isEmpty {
      let time = Date.FormatStyle(date: .omitted, time: .shortened)
      body += """


        **Recent problems** (this issue is public: remove any folder names you'd rather not share)
        ```
        \(model.recentFailures.map { "\($0.date.formatted(time))  \(shortened($0.text))" }.joined(separator: "\n"))
        ```
        """
    }
    var components = URLComponents(url: Links.issues, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "body", value: body)]
    return components?.url ?? Links.issues
  }

  /// The home folder as `~`, and long lines cut, so the link stays within GitHub's limits.
  static func shortened(_ text: String) -> String {
    let home = realHomeDirectory.path
    let short = text.replacingOccurrences(of: home, with: "~")
    return short.count > 300 ? String(short.prefix(299)) + "…" : short
  }
}
