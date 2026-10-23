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

/// Finds re-creatable folders under the folders the user granted: a kind's folder must sit next to its manifest, Cargo's `target/` must
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
  /// Folders in the home folder that never hold projects but take minutes to walk. The caches
  /// inside Library are found at their known locations instead (`caches(roots:)`).
  ///
  /// Desktop, Documents and Downloads are skipped too: macOS asks the user before an app reads
  /// them, even inside an allowed home folder, so walking in meant a prompt for each. A project
  /// kept there is added by choosing it, which counts as consent.
  public static let homeSkips: Set<String> = [
    "Library", "Pictures", "Music", "Movies", "Applications", "Public", "Desktop", "Documents",
    "Downloads",
  ]
  /// Packages that look like folders but are documents or apps.
  static let packageExtensions: Set<String> = [
    "app", "photoslibrary", "musiclibrary", "tvlibrary", "fcpbundle", "logicx", "xcarchive",
  ]

  public init() {}

  /// Candidates under each root, plus the machine-wide caches that exist under them.
  public func scan(roots: [String]) -> [Candidate] {
    var found: [Candidate] = []
    var seen = Set<String>()
    for root in Self.walkable(roots) {
      var st = stat()
      guard lstat(root, &st) == 0 else { continue }
      visit(
        URL(fileURLWithPath: root), device: st.st_dev, depth: 0, nodeAncestor: false, into: &found)
    }
    found += caches(roots: roots)
    return found.filter { seen.insert($0.path).inserted }
  }

  /// Scans one folder inside a root again (after a change there), seeing it as the full scan
  /// would: depth counts from the root, and a project with node_modules above it makes this
  /// one's node_modules part of that project's. Empty if the full scan wouldn't look there.
  public func scan(folder: String, roots: [String]) -> [Candidate] {
    guard
      let root = Self.walkable(roots).first(where: {
        folder == $0 || folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/")
      })
    else { return [] }
    let parts = folder.dropFirst(root.count).split(separator: "/").map(String.init)
    guard parts.count <= maxDepth else { return [] }
    // Folders the full scan skips in the home folder (Desktop, Documents…) aren't scanned here.
    if root == realHomeDirectory.standardizedFileURL.path, let first = parts.first,
      Self.homeSkips.contains(first)
    {
      return []
    }
    let inCheckout = folder.contains("/" + Self.checkoutFolders[0] + "/")
    if parts.contains(where: { $0 == "node_modules" || $0 == ".git" })
      || (parts.contains(where: { $0.hasPrefix(".") }) && !inCheckout)
    {
      return []
    }
    // Walk down from the root to the folder's parent, as visit would, to learn whether a
    // node_modules project lies above it (a checkout starts afresh) and to honor an ignore marker
    // anywhere above it.
    var nodeAncestor = false
    var dir = URL(fileURLWithPath: root)
    for part in parts {
      if FileManager.default.fileExists(atPath: dir.appendingPathComponent(Self.ignoreMarker).path)
      {
        return []
      }
      if let rule = Kind.node.projectRule,
        FileManager.default.fileExists(atPath: dir.appendingPathComponent(rule.manifest).path),
        isRealDirectory(dir.appendingPathComponent(rule.folderName).path)
      {
        nodeAncestor = true
      }
      dir = dir.appendingPathComponent(part)
      if dir.deletingLastPathComponent().path.hasSuffix("/" + Self.checkoutFolders[0]) {
        nodeAncestor = false
      }
    }
    var st = stat()
    guard lstat(folder, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return [] }
    var found: [Candidate] = []
    visit(
      URL(fileURLWithPath: folder), device: st.st_dev, depth: parts.count,
      nodeAncestor: nodeAncestor, into: &found)
    return found
  }

  /// The roots worth walking for projects. Cache folders granted for their caches (anything in
  /// ~/Library, or a hidden folder in the home folder such as ~/.cargo) hold no projects and are
  /// huge, so they're only searched for caches; a root inside another root is walked with it.
  public static func walkable(_ roots: [String]) -> [String] {
    let home = realHomeDirectory.standardizedFileURL.path
    return roots.filter { root in
      if root.hasPrefix(home + "/") {
        let first = root.dropFirst(home.count + 1).prefix { $0 != "/" }
        if first == "Library" || first.hasPrefix(".") { return false }
      }
      return !roots.contains { other in
        other != root && root.hasPrefix(other.hasSuffix("/") ? other : other + "/")
      }
    }
  }

  /// The machine-wide caches that exist under the roots. Instant, unlike walking the roots, so
  /// the app can show them while the walk runs.
  public func caches(roots: [String]) -> [Candidate] {
    var found: [Candidate] = []
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
    return found
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
    if dir.standardizedFileURL.path == realHomeDirectory.standardizedFileURL.path {
      skip.formUnion(Self.homeSkips)
    }
    for name in names.sorted()
    where !name.hasPrefix(".") && !skip.contains(name)
      && !Self.packageExtensions.contains((name as NSString).pathExtension.lowercased())
    {
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
          text.split(whereSeparator: \.isNewline).contains(where: {
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

  /// When a folder last changed: the newest modification time of the folder, everything up to
  /// two levels inside it, and its project's manifest and lockfiles. Two levels catch a build
  /// writing into `target/debug/deps` or `.next/cache`; deeper would be slow on big trees.
  public static func lastActivity(of candidate: Candidate) -> Date {
    var newest = Date.distantPast
    func consider(_ path: String) {
      var st = stat()
      if lstat(path, &st) == 0 {
        newest = max(newest, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
      }
    }
    consider(candidate.path)
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: candidate.path)) ?? [] {
      let child = candidate.path + "/" + name
      consider(child)
      if isRealDirectory(child) {
        for inner in ((try? fm.contentsOfDirectory(atPath: child)) ?? []).prefix(500) {
          consider(child + "/" + inner)
        }
      }
    }
    if let project = candidate.project {
      for name in [
        "package.json", "package-lock.json", "yarn.lock", "bun.lock", "Cargo.toml", "Cargo.lock",
        "pyproject.toml", "uv.lock",
      ] {
        consider(project + "/" + name)
      }
    }
    return newest
  }

  /// Whether a tool is working in the folder right now, where that can be told: Cargo holds a
  /// lock on `target/<profile>/.cargo-lock` for the whole build.
  public static func isBusy(_ candidate: Candidate) -> Bool {
    guard candidate.kind == .cargoTarget else { return false }
    for profile in subdirectories(of: candidate.url) {
      let lock = profile.appendingPathComponent(".cargo-lock").path
      let fd = open(lock, O_RDONLY | O_CLOEXEC | O_NOFOLLOW)
      guard fd >= 0 else { continue }
      defer { close(fd) }
      if flock(fd, LOCK_SH | LOCK_NB) != 0 { return true }
      flock(fd, LOCK_UN)
    }
    return false
  }
}
