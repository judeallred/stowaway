import Foundation
import StowawayCore

/// One line in the library: a re-creatable folder, on the Mac or on the drive.
struct Row: Identifiable, Hashable {
  enum Place: Hashable {
    case mac
    case drive
    /// Stowed, but the drive is away: tools are using a local folder meanwhile.
    case driveAway
  }

  var id: String { path }
  let kind: Kind
  let path: String
  let project: String?
  var place: Place
  /// Bytes on this Mac, once measured.
  var localBytes: Int64?
  /// Bytes on the drive.
  var driveBytes: Int64 = 0
  var lastActivity: Date?
  /// Engine entries that make up this row (a Cargo `target/` is stowed as several parts).
  var entryPaths: [String] = []
  /// The git checkout the project is in, so worktrees can be shown with their repository.
  var checkout: GitIndex.Checkout?

  var name: String {
    if let project { return (project as NSString).lastPathComponent }
    return kind.label
  }

  var candidate: Candidate { Candidate(kind: kind, path: path, project: project) }

  // For sorting and showing in the library.
  /// The size shown: on this Mac, or on the drive once stowed. (A stowed folder's local bytes
  /// are what stays behind, a Cargo target's built programs, or its size before it was stowed
  /// until the next measure; sorting by them put folders out of order.)
  var sortSize: Int64 {
    switch place {
    case .mac: localBytes ?? 0
    case .drive, .driveAway: driveBytes
    }
  }
  var sortDate: Date { lastActivity ?? .distantPast }
  var placeOrder: Int {
    switch place {
    case .mac: 0
    case .drive: 1
    case .driveAway: 2
    }
  }
  var sizeText: String {
    switch place {
    case .mac: localBytes.map(Format.bytes) ?? "…"
    case .drive, .driveAway: Format.bytes(driveBytes)
    }
  }
}

extension String {
  /// Whether this path is `base` or inside it (comparing the strings, without touching the disk).
  func isWithin(_ base: String) -> Bool {
    self == base || hasPrefix(base.hasSuffix("/") ? base : base + "/")
  }
}
