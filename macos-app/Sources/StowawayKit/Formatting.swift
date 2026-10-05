public import Foundation

/// Display formatting shared by the popover and the folders window (spec §14.5: numbers, not
/// adjectives).
public enum Format {
  /// Bytes the way Finder shows them: decimal units, e.g. "182.4 GB".
  public static func bytes(_ value: UInt64) -> String {
    if value < 1000 {
      return "\(value) bytes"
    }
    let units = ["KB", "MB", "GB", "TB", "PB"]
    var amount = Double(value) / 1000
    var index = 0
    while amount >= 1000, index < units.count - 1 {
      amount /= 1000
      index += 1
    }
    return String(format: "%.1f %@", amount, units[index])
  }

  /// A rate in MB/s, switching to GB/s above 1000.
  public static func rate(megabytesPerSecond value: Double) -> String {
    value >= 1000
      ? String(format: "%.1f GB/s", value / 1000)
      : String(format: "%.0f MB/s", value)
  }

  /// A rate from bytes per second.
  public static func rate(bytesPerSecond value: Double) -> String {
    rate(megabytesPerSecond: value / 1_000_000)
  }

  /// "about 6 s left", "about 3 min left".
  public static func remaining(_ seconds: Double) -> String {
    if seconds < 90 {
      return "about \(max(1, Int(seconds.rounded()))) s left"
    }
    return "about \(Int((seconds / 60).rounded())) min left"
  }

  /// A count with thousands separators, e.g. "8,200".
  public static func count(_ value: Double) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.maximumFractionDigits = 0
    formatter.locale = Locale(identifier: "en_US")
    return formatter.string(from: NSNumber(value: value)) ?? "\(Int(value))"
  }

  /// The last path components of a long path, e.g. "my-app/node_modules".
  public static func shortPath(_ path: String, components: Int = 2) -> String {
    let parts = path.split(separator: "/")
    return parts.suffix(components).joined(separator: "/")
  }

  /// "~/code" instead of "/Users/me/code".
  public static func abbreviatedPath(_ path: String, home: String = NSHomeDirectory()) -> String {
    path.hasPrefix(home + "/") || path == home ? "~" + path.dropFirst(home.count) : path
  }
}
