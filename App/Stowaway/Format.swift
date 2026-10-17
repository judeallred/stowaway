import Foundation
import StowawayCore

/// Display formatting: numbers, not adjectives.
enum Format {
  /// Bytes the way Finder shows them: decimal units, e.g. "182.4 GB".
  static func bytes(_ value: Int64) -> String {
    if value < 1000 { return "\(value) bytes" }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var amount = Double(value) / 1000
    var index = 0
    while amount >= 1000, index < units.count - 1 {
      amount /= 1000
      index += 1
    }
    // "100 GB", not "100.0 GB".
    let rounded = (amount * 10).rounded() / 10
    let number =
      rounded == rounded.rounded()
      ? String(format: "%.0f", rounded) : String(format: "%.1f", rounded)
    return "\(number) \(units[index])"
  }

  /// "~/code" instead of "/Users/me/code".
  static func path(_ path: String) -> String {
    let home = realHomeDirectory.path
    return path.hasPrefix(home + "/") || path == home ? "~" + path.dropFirst(home.count) : path
  }

  /// "3 days ago", "2 months ago".
  static func ago(_ date: Date?) -> String {
    guard let date, date > .distantPast else { return "—" }
    let formatter = RelativeDateTimeFormatter()
    formatter.unitsStyle = .full
    return formatter.localizedString(for: date, relativeTo: .now)
  }
}
