import Foundation
import os

/// One folder Stowaway keeps on the offload drive.
public struct Entry: Codable, Sendable, Identifiable, Equatable {
  public var id: String
  /// Where tools expect the folder.
  public var local: String
  /// Where it lives, relative to this Mac's store on the drive.
  public var remote: String
  /// Whether `local` currently points at the drive (for `.packages`, its packages do).
  public var online: Bool
  public var adoptedAt: Date
  public var mode: Mode = .folder
  public var kind: Kind?
  /// Bytes moved to the drive when it was offloaded.
  public var bytes: Int64 = 0

  public enum Mode: String, Codable, Sendable {
    /// The whole folder is a symlink to the drive.
    case folder
    /// An npm-style node_modules: package folders stay real and their contents link to the drive
    /// (see DeepLinks.swift).
    case packages
  }

  public init(
    id: String, local: String, remote: String, online: Bool, adoptedAt: Date, mode: Mode = .folder,
    kind: Kind? = nil, bytes: Int64 = 0
  ) {
    self.id = id
    self.local = local
    self.remote = remote
    self.online = online
    self.adoptedAt = adoptedAt
    self.mode = mode
    self.kind = kind
    self.bytes = bytes
  }

  private enum CodingKeys: String, CodingKey {
    case id, local, remote, online, adoptedAt, mode, kind, bytes
  }

  public init(from decoder: any Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    id = try c.decode(String.self, forKey: .id)
    local = try c.decode(String.self, forKey: .local)
    remote = try c.decode(String.self, forKey: .remote)
    online = try c.decode(Bool.self, forKey: .online)
    adoptedAt = try c.decode(Date.self, forKey: .adoptedAt)
    mode = try c.decodeIfPresent(Mode.self, forKey: .mode) ?? .folder
    kind = try c.decodeIfPresent(Kind.self, forKey: .kind)
    bytes = try c.decodeIfPresent(Int64.self, forKey: .bytes) ?? 0
  }
}

/// Keeps re-creatable folders on an external drive behind symlinks, inside the App Sandbox.
///
/// Each folder moves to the drive and a symlink takes its place. While the drive is away each
/// symlink is swapped for an empty local folder so tools keep working; when it returns, whatever
/// was built locally is merged onto the drive and the symlink comes back. npm projects use deep
/// links instead (DeepLinks.swift), because npm rejects a symlinked node_modules.
///
/// Access comes only from folders the user granted (kept as security-scoped bookmarks). The
/// `files.user-selected.executable` entitlement keeps the files it copies unquarantined, so
/// binaries on the drive still run.
public final class Engine: @unchecked Sendable {
  /// The folder Stowaway creates in the offload location. Spotlight skips `*.noindex` folders.
  public static let storeFolderName = "Stowaway.noindex"

  public enum GrantRole: Sendable {
    /// A folder to scan and manage, such as `~/code` or `~/.npm`.
    case root
    /// Where offloaded folders go: an external drive, or any folder.
    case drive
  }

  private let defaults: UserDefaults
  let stateDirectory: URL
  private let lock = NSLock()
  private var scoped: [URL] = []
  let logger = Logger(subsystem: "com.brooklynspaceport.stowaway", category: "engine")

  /// Receives one line per notable event (the app shows the latest; tests print them).
  public var log: @Sendable (String) -> Void = { _ in }
  /// Set by long-running processes: replaced local copies are deleted in the background instead
  /// of before an operation returns.
  public var cleanupInBackground = false
  /// How long an npm node_modules must be untouched before packages an install brought back are
  /// offloaded again.
  public var quietPeriod: TimeInterval = 20
  /// How much a new offload may bring the drive's total to, or nil for no limit (the free tier
  /// has one; any purchase lifts it). Only new offloads are refused: folders already on the
  /// drive keep working, and bringing folders back or deleting them is never limited.
  public var offloadLimit: Int64?

  public init(defaults: UserDefaults = .standard, stateDirectory: URL? = nil) {
    self.defaults = defaults
    let support =
      stateDirectory
      ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("Stowaway", isDirectory: true)
    try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
    self.stateDirectory = support
  }

  var stateURL: URL { stateDirectory.appendingPathComponent("entries.json") }

  func note(_ message: String) {
    logger.info("\(message, privacy: .private)")
    log(message)
  }

  // MARK: Identity

  /// Identifies this Mac's store on a shared drive. Random, never derived from hardware.
  public var installID: String {
    if let id = defaults.string(forKey: "installID") { return id }
    let id = UUID().uuidString.lowercased()
    defaults.set(id, forKey: "installID")
    return id
  }

  // MARK: Grants

  /// Saves a folder the user granted in an open panel.
  public func grant(_ url: URL, as role: GrantRole) throws {
    let data = try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    switch role {
    case .drive:
      defaults.set(data, forKey: "drive")
    case .root:
      var roots = rootBookmarks().filter { resolvePath($0) != url.standardizedFileURL.path }
      roots.append(data)
      defaults.set(roots, forKey: "roots")
    }
  }

  /// Forgets a root. Folders already offloaded from it stay managed.
  public func revokeRoot(_ path: String) {
    defaults.set(rootBookmarks().filter { resolvePath($0) != path }, forKey: "roots")
  }

  /// Forgets the offload location. Refused while anything is on it.
  public func forgetDrive() throws {
    guard entries().isEmpty else {
      throw StowawayError("bring every folder back before choosing a different location")
    }
    defaults.removeObject(forKey: "drive")
  }

  public var rootPaths: [String] { rootBookmarks().compactMap(resolvePath) }

  public var drivePath: String? { defaults.data(forKey: "drive").flatMap(resolvePath) }

  private func rootBookmarks() -> [Data] { defaults.array(forKey: "roots") as? [Data] ?? [] }

  private func resolvePath(_ data: Data) -> String? {
    var stale = false
    return
      (try? URL(
        resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale))?.standardizedFileURL.path
  }

  /// Starts accessing every granted folder. Returns this Mac's store on the offload location if
  /// it's connected.
  @discardableResult
  public func enterGrants() -> URL? {
    lock.withLock {
      for url in scoped { url.stopAccessingSecurityScopedResource() }
      scoped = []
      var refreshed: [Data] = []
      for data in rootBookmarks() {
        if let (url, fresh) = access(data) {
          scoped.append(url)
          refreshed.append(fresh)
        } else {
          refreshed.append(data)
        }
      }
      defaults.set(refreshed, forKey: "roots")
      guard let data = defaults.data(forKey: "drive"), let (drive, fresh) = access(data) else {
        return nil
      }
      defaults.set(fresh, forKey: "drive")
      scoped.append(drive)
      guard FileManager.default.fileExists(atPath: drive.path) else { return nil }
      let store = drive.appendingPathComponent(Self.storeFolderName).appendingPathComponent(
        installID)
      try? FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
      return store
    }
  }

  /// Resolves and starts accessing a bookmark, re-creating it if it went stale.
  private func access(_ data: Data) -> (URL, Data)? {
    var stale = false
    // Never try to mount or ask the user: when the drive has just gone, resolving must fail fast.
    guard
      let url = try? URL(
        resolvingBookmarkData: data, options: [.withSecurityScope, .withoutMounting, .withoutUI],
        relativeTo: nil,
        bookmarkDataIsStale: &stale),
      url.startAccessingSecurityScopedResource()
    else { return nil }
    if stale,
      let fresh = try? url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    {
      return (url, fresh)
    }
    return (url, data)
  }

  /// Whether `path` is inside a granted root (and isn't the root itself).
  public func isInsideRoot(_ path: String) -> Bool {
    let path = URL(fileURLWithPath: path).standardizedFileURL.path
    return rootPaths.contains { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
  }

  // MARK: Serializing

  /// Runs `body` holding an exclusive lock shared by every Stowaway process, so a release can't
  /// race a background re-offload. Public operations take it once; what they call doesn't.
  func exclusively<T>(_ body: () throws -> T) throws -> T {
    let path = stateDirectory.appendingPathComponent("engine.lock").path
    let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
    guard fd >= 0 else { throw StowawayError("can't open \(path)") }
    defer { close(fd) }
    flock(fd, LOCK_EX)
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  // MARK: State

  public func entries() -> [Entry] {
    guard let data = try? Data(contentsOf: stateURL) else { return [] }
    return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
  }

  func save(_ entries: [Entry]) {
    try? JSONEncoder().encode(entries).write(to: stateURL, options: .atomic)
  }

  func update(_ id: String, _ change: (inout Entry) -> Void) {
    var all = entries()
    if let i = all.firstIndex(where: { $0.id == id }) { change(&all[i]) }
    save(all)
  }

  /// Total bytes on the drive.
  public var offloadedBytes: Int64 { entries().reduce(0) { $0 + $1.bytes } }

  // MARK: Adopt and release

  /// Moves `path` onto the offload location: npm's node_modules package by package, anything
  /// else as one folder behind a symlink.
  @discardableResult
  public func adopt(_ path: String, kind: Kind? = nil, allowTurbopack: Bool = false) throws
    -> CopyStats
  {
    try exclusively { try adoptUnlocked(path, kind: kind, allowTurbopack: allowTurbopack) }
  }

  private func adoptUnlocked(_ path: String, kind: Kind?, allowTurbopack: Bool) throws -> CopyStats
  {
    let local = URL(fileURLWithPath: path).standardizedFileURL
    guard let store = enterGrants() else {
      throw StowawayError("the offload location isn't connected")
    }
    try validateAdoptable(local, store: store)
    if let limit = offloadLimit {
      let needed = Measure.allocatedSize(local.path)
      let used = offloadedBytes
      if used + needed > limit {
        throw OffloadLimitReached(limit: limit, used: used, needed: needed)
      }
    }
    if local.lastPathComponent == "node_modules" {
      return try adoptPackages(local, store: store, allowTurbopack: allowTurbopack)
    }
    let fm = FileManager.default
    let id = String(UUID().uuidString.prefix(8).lowercased())
    let slot = "\(local.lastPathComponent)-\(id)"
    let remoteRel = "\(slot)/\(local.lastPathComponent)"
    let remote = store.appendingPathComponent(remoteRel)
    let stats = try Copier.copyContents(of: local, into: remote)
    // Build output in a JavaScript project (Next.js's .next) requires the project's packages at
    // run time, and Node looks for them from the file's real path on the drive: put a
    // node_modules link next to it that leads back to the project's.
    let project = local.deletingLastPathComponent()
    if fm.fileExists(atPath: project.appendingPathComponent("package.json").path) {
      try? fm.createSymbolicLink(
        at: store.appendingPathComponent(slot).appendingPathComponent("node_modules"),
        withDestinationURL: project.appendingPathComponent("node_modules"))
    }
    let old = local.deletingLastPathComponent().appendingPathComponent(
      ".\(local.lastPathComponent).stowaway-old-\(id)")
    try fm.moveItem(at: local, to: old)
    do {
      try fm.createSymbolicLink(at: local, withDestinationURL: remote)
    } catch {
      try? fm.moveItem(at: old, to: local)
      throw error
    }
    var all = entries()
    all.append(
      Entry(
        id: id, local: local.path, remote: remoteRel, online: true, adoptedAt: Date(),
        kind: kind ?? Kind.forFolderName(local.lastPathComponent),
        bytes: stats.bytes))
    save(all)
    deleteSoon(old)
    note("offloaded \(local.path): \(stats)")
    return stats
  }

  /// Refuses anything Stowaway must not move.
  func validateAdoptable(_ local: URL, store: URL) throws {
    guard isRealDirectory(local.path) else { throw StowawayError("\(local.path) isn't a folder") }
    guard isInsideRoot(local.path) else {
      throw StowawayError("\(local.path) isn't inside a folder you've given Stowaway")
    }
    let storePath = store.standardizedFileURL.path
    guard !local.path.hasPrefix(storePath), !storePath.hasPrefix(local.path + "/") else {
      throw StowawayError("\(local.path) overlaps the offload location")
    }
    for entry in entries()
    where local.path == entry.local || local.path.hasPrefix(entry.local + "/")
      || entry.local.hasPrefix(local.path + "/")
    {
      throw StowawayError("\(local.path) overlaps \(entry.local), which is already offloaded")
    }
    switch GitIndex.tracking(of: local) {
    case .untracked: break
    case .tracked:
      throw StowawayError("git tracks files in \(local.path), so Stowaway leaves it alone")
    case .unknown:
      throw StowawayError(
        "couldn't read the git repository around \(local.path), so Stowaway leaves it alone")
    }
  }

  /// Brings a folder back to the Mac for good. Always allowed, purchase or not.
  public func release(_ path: String) throws {
    try exclusively { try releaseUnlocked(path) }
  }

  private func releaseUnlocked(_ path: String) throws {
    let store = enterGrants()
    let fm = FileManager.default
    guard let entry = entries().first(where: { $0.local == path }) else {
      throw StowawayError("\(path) isn't offloaded")
    }
    if entry.mode == .packages {
      try releasePackages(entry, store: store)
      save(entries().filter { $0.id != entry.id })
      return
    }
    if entry.online {
      guard let store else {
        throw StowawayError("connect the offload location to bring \(path) back")
      }
      let remote = try storePath(entry.remote, in: store)
      guard isSymlink(path) else { throw StowawayError("\(path) isn't Stowaway's link any more") }
      let staging = URL(fileURLWithPath: path + ".stowaway-releasing")
      let stats = try Copier.copyContents(of: remote, into: staging)
      try fm.removeItem(atPath: path)
      try fm.moveItem(at: staging, to: URL(fileURLWithPath: path))
      try Copier.remove(remote.deletingLastPathComponent())
      note("brought back \(path): \(stats)")
    }
    save(entries().filter { $0.id != entry.id })
  }

  /// Deletes an offloaded folder everywhere: the link (or the local folder while the drive is
  /// away) and its copy on the drive. A machine-wide cache folder is left empty rather than
  /// removed, so the permission the user granted for it stays valid.
  public func discard(_ path: String) throws {
    try exclusively {
      guard let entry = entries().first(where: { $0.local == path }) else {
        throw StowawayError("\(path) isn't offloaded")
      }
      guard let store = enterGrants() else {
        throw StowawayError("connect the offload location to delete \(path)")
      }
      let remote = try storePath(entry.remote, in: store)
      try Copier.remove(entry.mode == .packages ? remote : remote.deletingLastPathComponent())
      try Copier.remove(URL(fileURLWithPath: path))
      if entry.kind?.isGlobal == true {
        try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: false)
      }
      save(entries().filter { $0.id != entry.id })
      note("deleted \(path) and its copy on the drive")
    }
  }

  /// Resolves a path recorded relative to the store, refusing anything that escapes it (the
  /// drive is shared and its contents aren't trusted).
  func storePath(_ relative: String, in store: URL) throws -> URL {
    let components = relative.split(separator: "/")
    guard !relative.hasPrefix("/"), !components.isEmpty,
      !components.contains(where: { $0 == ".." || $0 == "." })
    else {
      throw StowawayError("refusing an unexpected path on the drive: \(relative)")
    }
    return store.appendingPathComponent(relative)
  }

  // MARK: The drive coming and going

  /// Makes every entry match whether the offload location is connected. Run at launch, when
  /// volumes change and periodically (to re-offload what an npm install brought back).
  public func reconcile() {
    _ = try? exclusively { reconcileUnlocked() }
  }

  private func reconcileUnlocked() {
    let store = enterGrants()
    for entry in entries() {
      if entry.mode == .packages {
        reconcilePackages(entry, store: store)
        continue
      }
      let isLink = isSymlink(entry.local)
      if let store, !entry.online {
        goOnline(entry, store: store)
      } else if store == nil, entry.online {
        goOffline(entry)
      } else if let store, entry.online, !isLink,
        FileManager.default.fileExists(atPath: entry.local)
      {
        // A tool replaced the symlink (cargo clean, uv venv --clear): merge what's there.
        note("\(entry.local) was replaced by a real folder; merging it onto the drive")
        update(entry.id) { $0.online = false }
        if let fresh = entries().first(where: { $0.id == entry.id }) {
          goOnline(fresh, store: store)
        }
      }
    }
  }

  private func goOffline(_ entry: Entry) {
    let fm = FileManager.default
    do {
      if isSymlink(entry.local) { try fm.removeItem(atPath: entry.local) }
      if !fm.fileExists(atPath: entry.local) {
        try fm.createDirectory(atPath: entry.local, withIntermediateDirectories: false)
      }
      update(entry.id) { $0.online = false }
      note("the drive is away: \(entry.local) is a local folder until it returns")
    } catch {
      note("couldn't switch \(entry.local) to a local folder: \(error.localizedDescription)")
    }
  }

  private func goOnline(_ entry: Entry, store: URL) {
    let fm = FileManager.default
    let local = URL(fileURLWithPath: entry.local)
    do {
      let remote = try storePath(entry.remote, in: store)
      var stats = CopyStats()
      if isRealDirectory(local.path) {
        stats = try Copier.copyContents(of: local, into: remote)
        let old = local.deletingLastPathComponent().appendingPathComponent(
          ".\(local.lastPathComponent).stowaway-old-\(entry.id)")
        try fm.moveItem(at: local, to: old)
        try fm.createSymbolicLink(at: local, withDestinationURL: remote)
        deleteSoon(old)
      } else if !fm.fileExists(atPath: local.path), !isSymlink(local.path) {
        // The project was moved or deleted while the drive was away.
        guard fm.fileExists(atPath: local.deletingLastPathComponent().path) else { return }
        try fm.createSymbolicLink(at: local, withDestinationURL: remote)
      }
      update(entry.id) {
        $0.online = true
        $0.bytes += stats.bytes
      }
      note("the drive is back: \(entry.local) is on it again (\(stats))")
    } catch {
      note("couldn't move \(entry.local) back onto the drive: \(error.localizedDescription)")
    }
  }

  /// Deletes a folder: in the background when this engine runs in a long-lived process (the
  /// links are already in place, so nothing waits on it), otherwise right away.
  func deleteSoon(_ url: URL) {
    if cleanupInBackground {
      DispatchQueue.global(qos: .utility).async { try? Copier.remove(url) }
    } else {
      try? Copier.remove(url)
    }
  }
}

/// A new offload would take the drive past the free tier's allowance.
public struct OffloadLimitReached: LocalizedError, Equatable {
  public let limit: Int64
  public let used: Int64
  public let needed: Int64
  public var errorDescription: String? {
    let format = ByteCountFormatter()
    return "Offloading this would take you past the free \(format.string(fromByteCount: limit))."
  }
}

public struct StowawayError: LocalizedError, Equatable {
  public let message: String
  public init(_ message: String) { self.message = message }
  public var errorDescription: String? { message }
}
