import Foundation

/// One folder Lite manages.
public struct Entry: Codable, Sendable, Identifiable {
  public var id: String
  /// Where tools expect the folder.
  public var local: String
  /// Where it lives on the drive, relative to the drive's root.
  public var remote: String
  /// Whether `local` is currently a symlink to the drive (or, for `.packages`, its packages are).
  public var online: Bool
  public var adoptedAt: Date
  public var mode: Mode = .folder

  public enum Mode: String, Codable, Sendable {
    /// The whole folder is a symlink to the drive.
    case folder
    /// An npm-style node_modules: the folder stays real and each package in it is a symlink
    /// (npm deletes a symlinked node_modules, but tolerates symlinked packages until it next runs).
    case packages
  }
}

extension Entry {
  private enum CodingKeys: String, CodingKey { case id, local, remote, online, adoptedAt, mode }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    local = try c.decode(String.self, forKey: .local)
    remote = try c.decode(String.self, forKey: .remote)
    online = try c.decode(Bool.self, forKey: .online)
    adoptedAt = try c.decode(Date.self, forKey: .adoptedAt)
    mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .folder
  }
}

/// Stowaway Lite: managed folders live on the drive behind symlinks. While the drive is away each
/// symlink is swapped for an empty local folder so tools keep working; when it returns, whatever
/// was built locally is merged onto the drive and the symlink comes back.
///
/// Everything runs inside the App Sandbox. Access comes from folders the user granted (kept as
/// security-scoped bookmarks), and the `files.user-selected.executable` entitlement keeps the
/// files it copies unquarantined, so binaries on the drive still run.
public final class Engine: @unchecked Sendable {
  /// Spotlight skips folders named `*.noindex`, as the core engine relies on too: indexing build
  /// folders and caches is wasted work.
  public static let driveFolder = "Stowaway Lite.noindex"

  private let defaults: UserDefaults
  private let stateURL: URL
  private let lock = NSLock()
  private var scoped: [URL] = []
  public var log: @Sendable (String) -> Void = { print($0) }
  /// Set by long-running processes (the app, `--watch`): replaced local copies are deleted in the
  /// background instead of before an operation returns.
  public var cleanupInBackground = false

  public init(defaults: UserDefaults = .standard) {
    self.defaults = defaults
    let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    stateURL = support.appendingPathComponent("lite-entries.json")
  }

  // MARK: Grants

  /// Saves a folder the user granted. Paths under /Volumes become the drive.
  public func grant(_ url: URL) throws {
    let data = try url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    if url.path.hasPrefix("/Volumes/") {
      defaults.set(data, forKey: "drive")
    } else {
      var roots = defaults.array(forKey: "roots") as? [Data] ?? []
      roots.append(data)
      defaults.set(roots, forKey: "roots")
    }
  }

  /// Starts accessing every granted folder. Returns the drive's root if it's connected.
  @discardableResult
  public func enterGrants() -> URL? {
    lock.withLock {
      for url in scoped { url.stopAccessingSecurityScopedResource() }
      scoped = []
      for data in (defaults.array(forKey: "roots") as? [Data] ?? []) {
        if let url = resolve(data) { scoped.append(url) }
      }
      guard let data = defaults.data(forKey: "drive"), let drive = resolve(data) else { return nil }
      scoped.append(drive)
      return FileManager.default.fileExists(atPath: drive.path) ? drive : nil
    }
  }

  private func resolve(_ data: Data) -> URL? {
    var stale = false
    guard
      // Never try to mount or ask the user: when the drive has just gone, resolving must fail fast.
      let url = try? URL(
        resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting, .withoutUI], relativeTo: nil,
        bookmarkDataIsStale: &stale),
      url.startAccessingSecurityScopedResource()
    else { return nil }
    return url
  }

  public var drivePath: String? {
    guard let data = defaults.data(forKey: "drive") else { return nil }
    var stale = false
    return (try? URL(resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting, .withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale))?.path
  }

  // MARK: Serializing

  /// Runs `body` holding an exclusive lock shared by every Lite process (the app and the command
  /// line), so a release can't race a background re-offload. Public operations take it once;
  /// what they call internally doesn't.
  func exclusively<T>(_ body: () throws -> T) throws -> T {
    let path = stateURL.deletingLastPathComponent().appendingPathComponent("lite.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw LiteError("can't open \(path)") }
    defer { close(fd) }
    flock(fd, LOCK_EX)
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  // MARK: State

  public func entries() -> [Entry] {
    (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: stateURL))) ?? []
  }

  func save(_ entries: [Entry]) {
    try? JSONEncoder().encode(entries).write(to: stateURL, options: .atomic)
  }

  func update(_ id: String, _ change: (inout Entry) -> Void) {
    var all = entries()
    if let i = all.firstIndex(where: { $0.id == id }) { change(&all[i]) }
    save(all)
  }

  // MARK: Adopt and release

  /// Moves `path` onto the drive and leaves a symlink. Copies first and swaps at the end, so the
  /// folder stays usable until the symlink appears.
  @discardableResult
  public func adopt(_ path: String, allowTurbopack: Bool = false) throws -> CopyStats {
    try exclusively { try adoptUnlocked(path, allowTurbopack: allowTurbopack) }
  }

  private func adoptUnlocked(_ path: String, allowTurbopack: Bool) throws -> CopyStats {
    let local = URL(fileURLWithPath: path).standardizedFileURL
    if local.lastPathComponent == "node_modules" {
      return try adoptPackages(local.path, allowTurbopack: allowTurbopack)
    }
    guard let drive = enterGrants() else { throw LiteError("the drive isn't connected or granted") }
    let fm = FileManager.default
    var isDir: ObjCBool = false
    guard fm.fileExists(atPath: local.path, isDirectory: &isDir), isDir.boolValue,
      (try? fm.destinationOfSymbolicLink(atPath: local.path)) == nil
    else { throw LiteError("\(local.path) isn't a folder") }
    guard !entries().contains(where: { $0.local == local.path }) else {
      throw LiteError("\(local.path) is already managed")
    }

    let id = UUID().uuidString.prefix(8).lowercased()
    let slot = "\(Self.driveFolder)/\(local.lastPathComponent)-\(id)"
    let remoteRel = "\(slot)/\(local.lastPathComponent)"
    let remote = drive.appendingPathComponent(remoteRel)
    let stats = try Copier.copyContents(of: local, into: remote)
    // Build output in a JavaScript project (Next.js's .next) requires the project's packages at
    // run time, and Node looks for them from the file's real path on the drive: put a node_modules
    // link next to it that leads back to the project's.
    let project = local.deletingLastPathComponent()
    if fm.fileExists(atPath: project.appendingPathComponent("package.json").path) {
      try? fm.createSymbolicLink(
        at: drive.appendingPathComponent(slot).appendingPathComponent("node_modules"),
        withDestinationURL: project.appendingPathComponent("node_modules"))
    }
    let old = local.deletingLastPathComponent().appendingPathComponent(".\(local.lastPathComponent).stowaway-old-\(id)")
    try fm.moveItem(at: local, to: old)
    do {
      try fm.createSymbolicLink(at: local, withDestinationURL: remote)
    } catch {
      try? fm.moveItem(at: old, to: local)
      throw error
    }
    var all = entries()
    all.append(Entry(id: String(id), local: local.path, remote: remoteRel, online: true, adoptedAt: Date()))
    save(all)
    try Copier.remove(old)
    log("adopted \(local.path): \(stats)")
    return stats
  }

  /// Brings a folder back to the Mac for good.
  public func release(_ path: String) throws {
    try exclusively { try releaseUnlocked(path) }
  }

  private func releaseUnlocked(_ path: String) throws {
    let drive = enterGrants()
    let fm = FileManager.default
    guard let entry = entries().first(where: { $0.local == path }) else { throw LiteError("\(path) isn't managed") }
    if entry.mode == .packages {
      try releasePackages(entry, drive: drive)
      save(entries().filter { $0.id != entry.id })
      return
    }
    if entry.online {
      guard let drive else { throw LiteError("connect the drive to release \(path)") }
      let remote = drive.appendingPathComponent(entry.remote)
      let staging = URL(fileURLWithPath: path + ".stowaway-releasing")
      let stats = try Copier.copyContents(of: remote, into: staging)
      try fm.removeItem(atPath: path)
      try fm.moveItem(at: staging, to: URL(fileURLWithPath: path))
      try Copier.remove(remote)
      let slot = remote.deletingLastPathComponent()
      if slot.lastPathComponent != Self.driveFolder { try? Copier.remove(slot) }
      log("released \(path): \(stats)")
    }
    save(entries().filter { $0.id != entry.id })
  }

  // MARK: The drive coming and going

  /// Makes every entry match whether the drive is here. Run at launch and whenever volumes change.
  public func reconcile() {
    _ = try? exclusively { reconcileUnlocked() }
  }

  private func reconcileUnlocked() {
    let drive = enterGrants()
    for entry in entries() {
      if entry.mode == .packages {
        reconcilePackages(entry, drive: drive)
        continue
      }
      if let drive, !entry.online {
        goOnline(entry, drive: drive)
      } else if drive == nil, entry.online {
        goOffline(entry)
      } else if entry.online, (try? FileManager.default.destinationOfSymbolicLink(atPath: entry.local)) == nil {
        // A tool replaced the symlink (cargo clean, uv venv --clear): adopt what's there again.
        log("\(entry.local) was replaced by a real folder; it'll be merged onto the drive")
        update(entry.id) { $0.online = false }
        if let drive, let fresh = entries().first(where: { $0.id == entry.id }) { goOnline(fresh, drive: drive) }
      }
    }
  }

  private func goOffline(_ entry: Entry) {
    let fm = FileManager.default
    do {
      if (try? fm.destinationOfSymbolicLink(atPath: entry.local)) != nil { try fm.removeItem(atPath: entry.local) }
      if !fm.fileExists(atPath: entry.local) { try fm.createDirectory(atPath: entry.local, withIntermediateDirectories: false) }
      update(entry.id) { $0.online = false }
      log("offline: \(entry.local) is a local folder until the drive returns")
    } catch {
      log("couldn't take \(entry.local) offline: \(error.localizedDescription)")
    }
  }

  private func goOnline(_ entry: Entry, drive: URL) {
    let fm = FileManager.default
    let local = URL(fileURLWithPath: entry.local)
    let remote = drive.appendingPathComponent(entry.remote)
    do {
      var stats = CopyStats()
      if fm.fileExists(atPath: local.path), (try? fm.destinationOfSymbolicLink(atPath: local.path)) == nil {
        stats = try Copier.copyContents(of: local, into: remote)
        let old = local.deletingLastPathComponent().appendingPathComponent(".\(local.lastPathComponent).stowaway-old-\(entry.id)")
        try fm.moveItem(at: local, to: old)
        try fm.createSymbolicLink(at: local, withDestinationURL: remote)
        try Copier.remove(old)
      } else if !fm.fileExists(atPath: local.path) {
        try fm.createSymbolicLink(at: local, withDestinationURL: remote)
      }
      update(entry.id) { $0.online = true }
      log("online: \(entry.local) → drive, merged \(stats)")
    } catch {
      log("couldn't bring \(entry.local) online: \(error.localizedDescription)")
    }
  }
}
