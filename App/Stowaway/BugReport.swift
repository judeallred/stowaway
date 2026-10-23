import Foundation
import StowawayCore

/// A prefilled GitHub issue. Nothing is sent until the user reviews and submits it in their
/// browser. It carries versions, counts, and the last few failures, with paths, file names and
/// the drive's name replaced by `[REDACTED]`, since the issue is public.
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
    if let drive = model.drivePath {
      body +=
        "\nDrive location: \(AppModel.describeLocation(URL(fileURLWithPath: drive), relativeTo: nil))"
    }
    if !model.driveChoices.isEmpty {
      body += """


        **Drive choices**
        ```
        \(model.driveChoices.joined(separator: "\n"))
        ```
        """
    }
    if !model.recentFailures.isEmpty {
      let redactor = Redactor(
        known: [realHomeDirectory.path, model.drivePath, model.lastDrivePath, model.driveName]
          .compactMap { $0 } + model.roots + model.rows.map(\.path))
      let time = Date.FormatStyle(date: .omitted, time: .shortened)
      body += """


        **Recent problems** (personal details redacted; this issue is public)
        ```
        \(model.recentFailures.map { "\($0.date.formatted(time))  \(shortened(redactor.redact($0.text)))" }.joined(separator: "\n"))
        ```
        """
    }
    var components = URLComponents(url: Links.issues, resolvingAgainstBaseURL: false)
    components?.queryItems = [URLQueryItem(name: "body", value: body)]
    return components?.url ?? Links.issues
  }

  /// Long lines cut, so the link stays within GitHub's limits.
  static func shortened(_ text: String) -> String {
    text.count > 300 ? String(text.prefix(299)) + "…" : text
  }
}
