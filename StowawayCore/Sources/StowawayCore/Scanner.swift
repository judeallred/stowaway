import Foundation

/// A re-creatable folder Stowaway found.
public struct Candidate: Identifiable, Hashable, Sendable {
  public var id: String { path }
  public let kind: Kind
  public let path: String
  /// The project folder for project kinds (where `package.json`, `Cargo.toml`… are).
  public let project: String?

  public init(kind: Kind, path: String, project: String?) {
    self.kind = kind
    self.path = path
    self.project = project
  }

  public var url: URL { URL(fileURLWithPath: path) }
  public var name: String {
    if let project { return URL(fileURLWithPath: project).lastPathComponent }
    return url.lastPathComponent
  }
}

/// Finds re-creatable folders under the folders the user granted, following the same rules as
/// the original engine: a kind's folder must sit next to its manifest, Cargo's `target/` must
/// carry `CACHEDIR.TAG` and not be redirected, a `node_modules` inside another project's tree is
/// left to the outer one, and nothing on another volume, behind a symlink or under a
/// `.stowaway-ignore` marker is touched.
public struct Scanner: Sendable {
  /// Marker file that excludes a folder and everything under it.
  public static let ignoreMarker = ".stowaway-ignore"
  /// Hidden folders inside a project that hold whole checkouts, scanned as separate projects:
  /// Claude Code's worktrees.
  static let checkoutFolders = [".claude/worktrees"]

  public var maxDepth = 6

  public init() {}

  /// Candidates under each root, plus the machine-wide caches that exist under them.
  public func scan(roots: [String]) -> [Candidate] {
    var found: [Candidate] = []
    var seen = Set<String>()
    for root in roots {
      var st = stat()
      guard lstat(root, &st) == 0 else { continue }
      visit(
        URL(fileURLWithPath: root), device: st.st_dev, depth: 0, nodeAncestor: false, into: &found)
    }
    for kind in Kind.allCases where kind.isGlobal {
      for rel in kind.defaultLocations {
        let path = realHomeDirectory.appendingPathComponent(rel).standardizedFileURL.path
        guard
          roots.contains(where: { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") })
        else { continue }
        if isRealDirectory(path) || isSymlink(path) {
          found.append(Candidate(kind: kind, path: path, project: nil))
        }
      }
    }
    return found.filter { seen.insert($0.path).inserted }
  }

  private func visit(
    _ dir: URL, device: dev_t, depth: Int, nodeAncestor: Bool, into found: inout [Candidate]
  ) {
    let fm = FileManager.default
    if fm.fileExists(atPath: dir.appendingPathComponent(Self.ignoreMarker).path) { return }
    guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
    let present = Set(names)
    var skip: Set<String> = [".git", "node_modules"]
    var childrenHaveNodeAncestor = nodeAncestor

    for kind in Kind.allCases {
      guard let rule = kind.projectRule, present.contains(rule.manifest) else { continue }
      skip.insert(rule.folderName)
      let folder = dir.appendingPathComponent(rule.folderName)
      // Offloaded folders are symlinks; the engine lists those itself.
      guard present.contains(rule.folderName), isRealDirectory(folder.path) else { continue }
      if kind == .node {
        childrenHaveNodeAncestor = true
        if nodeAncestor { continue }
      }
      if kind == .cargoTarget, Self.cargoTargetRedirected(dir) { continue }
      if let marker = rule.requiredMarker,
        !fm.fileExists(atPath: folder.appendingPathComponent(marker).path)
      {
        continue
      }
      found.append(Candidate(kind: kind, path: folder.path, project: dir.path))
    }

    guard depth < maxDepth else { return }
    for name in names.sorted() where !name.hasPrefix(".") && !skip.contains(name) {
      let child = dir.appendingPathComponent(name)
      if isLocalDirectory(child.path, device: device) {
        visit(
          child, device: device, depth: depth + 1, nodeAncestor: childrenHaveNodeAncestor,
          into: &found)
      }
    }
    // Each checkout is its own project, so this one's node_modules isn't its ancestor.
    for checkouts in Self.checkoutFolders.map({ dir.appendingPathComponent($0) })
    where isLocalDirectory(checkouts.path, device: device) {
      for checkout in subdirectories(of: checkouts)
      where isLocalDirectory(checkout.path, device: device) {
        visit(checkout, device: device, depth: depth + 1, nodeAncestor: false, into: &found)
      }
    }
  }

  /// A real folder on the root's volume: symlinks and other volumes are skipped.
  private func isLocalDirectory(_ path: String, device: dev_t) -> Bool {
    var st = stat()
    return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR && st.st_dev == device
  }

  /// Whether a `.cargo/config.toml` in `dir` or an ancestor sets `target-dir`.
  static func cargoTargetRedirected(_ dir: URL) -> Bool {
    var current = dir
    while current.path != "/" {
      for name in ["config.toml", "config"] {
        let file = current.appendingPathComponent(".cargo").appendingPathComponent(name)
        if let text = try? String(contentsOf: file, encoding: .utf8),
          text.split(separator: "\n").contains(where: {
            $0.trimmingCharacters(in: .whitespaces).hasPrefix("target-dir")
          })
        {
          return true
        }
      }
      current = current.deletingLastPathComponent()
    }
    return false
  }
}

/// Disk usage and recency of folders.
public enum Measure {
  /// Bytes a folder takes on disk (allocated blocks), not following symlinks.
  public static func allocatedSize(_ path: String) -> Int64 {
    var total: Int64 = 0
    var paths: [UnsafeMutablePointer<CChar>?] = [strdup(path), nil]
    defer { free(paths[0]) }
    guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else { return 0 }
    defer { fts_close(fts) }
    while let entry = fts_read(fts) {
      switch Int32(entry.pointee.fts_info) {
      case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT, FTS_DP:
        if let st = entry.pointee.fts_statp { total += Int64(st.pointee.st_blocks) * 512 }
      default:
        break
      }
    }
    return total
  }

  /// When a project last changed: the newest of the folder itself, its top level and the
  /// project's manifest and lockfiles. Cheap, and good enough to rank folders by staleness.
  public static func lastActivity(of candidate: Candidate) -> Date {
    var newest = Date.distantPast
    func consider(_ path: String) {
      var st = stat()
      if lstat(path, &st) == 0 {
        newest = max(newest, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
      }
    }
    consider(candidate.path)
    for name in (try? FileManager.default.contentsOfDirectory(atPath: candidate.path)) ?? [] {
      consider(candidate.path + "/" + name)
    }
    if let project = candidate.project {
      for name in [
        "package.json", "package-lock.json", "yarn.lock", "Cargo.toml", "Cargo.lock",
        "pyproject.toml", "uv.lock",
      ] {
        consider(project + "/" + name)
      }
    }
    return newest
  }
}
