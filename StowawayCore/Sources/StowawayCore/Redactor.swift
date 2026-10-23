import Foundation

/// Removes personal details (paths, file and folder names, the drive's name) from text that
/// leaves the Mac, such as a bug report. A path keeps only its last component when that's a
/// kind's folder name (`[REDACTED]/node_modules`), which says what failed without saying where.
public struct Redactor: Sendable {
  public static let placeholder = "[REDACTED]"

  /// Strings known to be personal, longest first so a path is replaced before its parent.
  private let known: [String]

  /// - Parameter known: paths and names to remove wherever they appear, even when they hold
  ///   spaces (which the path pattern alone can't see past).
  public init(known: [String]) {
    self.known = Set(known.filter { $0.count > 1 }).sorted { $0.count > $1.count }
  }

  public func redact(_ text: String) -> String {
    var text = text
    for string in known {
      text = text.replacingOccurrences(of: string, with: Self.replacement(forPath: string))
    }
    // Names in quotes, as Foundation's errors give them: The file “notes.txt” couldn't…
    text = text.replacing(/“[^”]*”/) { _ in "“\(Self.placeholder)”" }
    text = text.replacing(/‘[^’]*’/) { _ in "‘\(Self.placeholder)’" }
    text = text.replacing(/"[^"]*"/) { _ in "\"\(Self.placeholder)\"" }
    // Any remaining word that looks like a path, less punctuation that ends a sentence. Over-
    // eager on purpose: "and/or" goes too.
    return text.replacing(/[^\s"“”‘’]*[\/~][^\s"“”‘’]*/) { match in
      var path = Substring(match.output)
      var end = ""
      while let last = path.last, ".,:;)".contains(last) {
        end = String(last) + end
        path = path.dropLast()
      }
      return Self.replacement(forPath: String(path)) + end
    }
  }

  /// `[REDACTED]`, or `[REDACTED]/node_modules` for a path ending in a kind's folder.
  private static func replacement(forPath path: String) -> String {
    let last = (path as NSString).lastPathComponent
    if path.contains("/"), Kind.forFolderName(last) != nil {
      return "\(placeholder)/\(last)"
    }
    return placeholder
  }
}
