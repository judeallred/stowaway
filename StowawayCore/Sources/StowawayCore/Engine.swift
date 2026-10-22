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
  /// Bytes the folder takes on the drive.
  public var bytes: Int64 = 0
  /// The folder this entry is part of, when it's one of several (a Cargo `target/`'s build
  /// folders, DerivedData's intermediates); the folder itself otherwise. Recorded when offloaded,
  /// so it's never guessed from the path.
  public var container: String?

  public enum Mode: String, Codable, Sendable {
    /// The whole folder is a symlink to the drive.
    case folder
    /// An npm-style node_modules: package folders stay real and their contents link to the drive
    /// (see DeepLinks.swift).
    case packages
  }

  public init(
    id: String, local: String, remote: String, online: Bool, adoptedAt: Date, mode: Mode = .folder,
    kind: Kind? = nil, bytes: Int64 = 0, container: String? = nil
  ) {
    self.id = id
    self.local = local
    self.remote = remote
    self.online = online
    self.adoptedAt = adoptedAt
    self.mode = mode
    self.kind = kind
    self.bytes = bytes
    self.container = container
  }

  private enum CodingKeys: String, CodingKey {
    case id, local, remote, online, adoptedAt, mode, kind, bytes, container
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
    container = try c.decodeIfPresent(String.self, forKey: .container)
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
  /// Folders being accessed, by path. Access is started once and kept for the life of the
  /// process: stopping it while another thread is mid-operation would make that operation fail.
  private var scoped: [String: URL] = [:]
  /// For npm entries that are settled (everything on the drive, quiet), the top-level change
  /// time then. Reconcile skips them until it changes: walking every package of every project
  /// each time took minutes with many projects, holding the lock stowing needs.
  /// Kept in the engine's defaults, so the first reconcile after a launch is quick too.
  func settledChange(of id: String) -> Date? {
    lock.withLock {
      (defaults.dictionary(forKey: "settledPackages")?[id] as? Double).map {
        Date(timeIntervalSince1970: $0)
      }
    }
  }

  func setSettledChange(_ date: Date?, of id: String) {
    let ids = Set(entries().map(\.id))
    lock.withLock {
      var all = defaults.dictionary(forKey: "settledPackages") as? [String: Double] ?? [:]
      all[id] = date?.timeIntervalSince1970
      // Entries that no longer exist drop out.
      defaults.set(all.filter { ids.contains($0.key) }, forKey: "settledPackages")
    }
  }
  let logger = Logger(subsystem: "com.brooklynspaceport.stowaway", category: "engine")

  /// Receives one line per notable event (the app shows the latest; tests print them).
  public var log: @Sendable (String) -> Void = { _ in }
  /// Set by long-running processes: replaced local copies are deleted in the background instead
  /// of before an operation returns.
  public var cleanupInBackground = false
  /// How long an npm node_modules must be untouched before packages an install brought back are
  /// offloaded again.
  public var quietPeriod: TimeInterval = 20

  /// Paused: reconcile does what keeps tools working (local folders when the drive goes, links
  /// put right) but moves nothing onto the drive: no merging local builds back, no re-stowing
  /// what npm reinstalled. Those wait until it's resumed.
  public var paused: Bool {
    get { lock.withLock { isPaused } }
    set { lock.withLock { isPaused = newValue } }
  }
  private var isPaused = false

  public init(defaults: UserDefaults = .standard, stateDirectory: URL? = nil) {
    self.defaults = defaults
    let support =
      stateDirectory
      ?? (FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
      ?? FileManager.default.temporaryDirectory)
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
  ///
  /// A different offload location is refused while folders are offloaded, even when the current
  /// one is unplugged (it can't be resolved then, but the folders are still on it). Choosing the
  /// same drive again is fine: it already holds this Mac's store.
  public func grant(_ url: URL, as role: GrantRole) throws {
    let data = try url.bookmarkData(
      options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    switch role {
    case .drive:
      // With folders stowed, only the drive that holds them will do: every entry's copy must be
      // there. (Its store folder alone isn't proof: one is left behind after bringing
      // everything back.)
      let ours = url.appendingPathComponent(Self.storeFolderName).appendingPathComponent(installID)
      let holdsEverything = entries().allSatisfy { entry in
        (try? storePath(entry.remote, in: ours)).map { isRealDirectory($0.path) } ?? false
      }
      if !entries().isEmpty, !holdsEverything {
        throw StowawayError(
          "Stowaway keeps folders on \(driveName ?? "another drive"). Bring them back before choosing a different location."
        )
      }
      lock.withLock {
        defaults.set(data, forKey: "drive")
        defaults.set(url.lastPathComponent, forKey: "driveName")
      }
    case .root:
      lock.withLock {
        var roots = rootBookmarks().filter { resolvePath($0) != url.standardizedFileURL.path }
        roots.append(data)
        defaults.set(roots, forKey: "roots")
      }
    }
  }

  /// Forgets a root. Folders already offloaded from it stay managed.
  public func revokeRoot(_ path: String) {
    lock.withLock {
      defaults.set(rootBookmarks().filter { resolvePath($0) != path }, forKey: "roots")
    }
  }

  /// The offload location's name, remembered so it can be shown while it's unplugged.
  public var driveName: String? {
    defaults.data(forKey: "drive") == nil ? nil : defaults.string(forKey: "driveName")
  }

  /// Whether an offload location has been chosen (it may be unplugged).
  public var hasDrive: Bool { defaults.data(forKey: "drive") != nil }

  /// Forgets the offload location. Refused while anything is on it.
  public func forgetDrive() throws {
    try exclusively {
      guard entries().isEmpty else {
        throw StowawayError("bring every folder back before choosing a different location")
      }
      lock.withLock {
        defaults.removeObject(forKey: "drive")
        defaults.removeObject(forKey: "driveName")
      }
    }
  }

  /// Forgets the offload location while folders are still on it (it's gone for good, say). Each
  /// stowed folder becomes a local one, as when the drive is unplugged, for tools to rebuild
  /// into; npm deep links dangle until the next install repairs them. The copies on the drive
  /// are left where they are.
  public func abandonDrive() throws {
    try exclusively {
      let fm = FileManager.default
      // npm deep links: remove links into this install's store, leaving folders npm repairs.
      for entry in entries() where entry.mode == .packages {
        removeStoreLinks(under: URL(fileURLWithPath: entry.local))
      }
      for entry in entries() where entry.mode == .folder {
        if isSymlink(entry.local) { try? fm.removeItem(atPath: entry.local) }
        let parent = URL(fileURLWithPath: entry.local).deletingLastPathComponent().path
        if !fm.fileExists(atPath: entry.local), isRealDirectory(parent) {
          try? fm.createDirectory(atPath: entry.local, withIntermediateDirectories: false)
        }
      }
      save([])
      lock.withLock {
        defaults.removeObject(forKey: "drive")
        defaults.removeObject(forKey: "driveName")
      }
      note("forgot the offload location; its copies stay on the drive")
    }
  }

  /// Removes every symlink under `root` that leads into one of this install's stores.
  private func removeStoreLinks(under root: URL) {
    let fm = FileManager.default
    let marker = "/\(Self.storeFolderName)/\(installID)/"
    guard
      let walker = fm.enumerator(
        at: root, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [])
    else { return }
    for case let url as URL in walker {
      guard isSymlink(url.path),
        let destination = try? fm.destinationOfSymbolicLink(atPath: url.path),
        destination.contains(marker)
      else { continue }
      try? fm.removeItem(at: url)
    }
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
      let roots = rootBookmarks()
      var refreshed: [Data] = []
      for data in roots {
        refreshed.append(access(data)?.1 ?? data)
      }
      if refreshed != roots { defaults.set(refreshed, forKey: "roots") }
      guard let data = defaults.data(forKey: "drive"), let (drive, fresh) = access(data) else {
        return nil
      }
      if fresh != data { defaults.set(fresh, forKey: "drive") }
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
      scoped[url.standardizedFileURL.path] != nil || url.startAccessingSecurityScopedResource()
    else { return nil }
    scoped[url.standardizedFileURL.path] = url
    if stale,
      let fresh = try? url.bookmarkData(
        options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil)
    {
      return (url, fresh)
    }
    return (url, data)
  }

  /// Whether `path` is inside a granted root (and isn't the root itself).
  func isInsideRoot(_ path: String) -> Bool {
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
  ///
  /// `limit` is how much a new offload may bring the drive's total to (the free tier has one; any
  /// purchase lifts it). Only new offloads are refused: folders already on the drive keep working,
  /// and bringing folders back or deleting them is never limited. `container` is the folder this
  /// is part of, when it's one of several (a Cargo `target/`'s build folders).
  @discardableResult
  public func adopt(
    _ path: String, kind: Kind? = nil, container: String? = nil, limit: Int64? = nil,
    allowTurbopack: Bool = false
  ) throws -> CopyStats {
    try exclusively {
      try adoptUnlocked(
        path, kind: kind, container: container, limit: limit, allowTurbopack: allowTurbopack)
    }
  }

  private func adoptUnlocked(
    _ path: String, kind: Kind?, container: String?, limit: Int64?, allowTurbopack: Bool
  ) throws -> CopyStats {
    let local = URL(fileURLWithPath: path).standardizedFileURL
    guard let store = enterGrants() else {
      throw StowawayError("the drive isn't connected")
    }
    try validateAdoptable(local, store: store)
    if let limit {
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
    try checkContained(remote, in: store)
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
    // Record the entry before touching the local folder: from here on, a crash at any point
    // leaves something `recover` and `reconcile` can finish (the copy on the drive is complete).
    var all = entries()
    all.append(
      Entry(
        id: id, local: local.path, remote: remoteRel, online: true, adoptedAt: Date(),
        kind: kind ?? Kind.forFolderName(local.lastPathComponent),
        bytes: stats.bytes, container: container ?? local.path))
    save(all)
    let old = Self.leftoverName(for: local)
    try fm.moveItem(at: local, to: old)
    do {
      try fm.createSymbolicLink(at: local, withDestinationURL: remote)
    } catch {
      try? fm.moveItem(at: old, to: local)
      save(entries().filter { $0.id != id })
      throw error
    }
    deleteSoon(old)
    note("offloaded \(local.path): \(stats)")
    return stats
  }

  /// Refuses anything Stowaway must not move.
  func validateAdoptable(_ local: URL, store: URL) throws {
    guard isRealDirectory(local.path) else {
      throw StowawayError.refusal("\(local.path) isn't a folder")
    }
    guard isInsideRoot(local.path) else {
      throw StowawayError.refusal("\(local.path) isn't inside a folder you've given Stowaway")
    }
    let storePath = store.standardizedFileURL.path
    guard !local.path.hasPrefix(storePath), !storePath.hasPrefix(local.path + "/") else {
      throw StowawayError.refusal("\(local.path) overlaps where Stowaway stows folders")
    }
    for entry in entries()
    where local.path == entry.local || local.path.hasPrefix(entry.local + "/")
      || entry.local.hasPrefix(local.path + "/")
    {
      throw StowawayError.refusal("\(local.path) overlaps \(entry.local), which is already stowed")
    }
    if GitIndex.containsRepository(local) {
      throw StowawayError.refusal(
        "\(local.path) contains a git repository, so Stowaway leaves it alone")
    }
    switch GitIndex.tracking(of: local) {
    case .untracked: break
    case .tracked:
      throw StowawayError.refusal("git tracks files in \(local.path), so Stowaway leaves it alone")
    case .unknown:
      throw StowawayError(
        "couldn't read the git repository around \(local.path), so Stowaway leaves it alone")
    }
  }

  /// Deletes a re-creatable folder that isn't stowed (see `Cleaner`), holding the engine's lock so
  /// it can't interleave with stowing the same folder. The folder goes at once; erasing its
  /// files finishes in the background (`trash`).
  public func delete(_ candidate: Candidate, roots: [String]) throws {
    try exclusively {
      try Cleaner().delete(candidate, roots: roots, offloaded: entries(), remove: trash)
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
      throw StowawayError("\(path) isn't stowed")
    }
    if entry.mode == .packages {
      try releasePackages(entry, store: store)
      save(entries().filter { $0.id != entry.id })
      return
    }
    guard let store else {
      throw StowawayError("connect the drive to bring \(path) back")
    }
    var current = entry
    if !current.online {
      // The drive is connected but this folder is still local (the reconnect didn't finish):
      // merge it onto the drive first, so nothing on either side is lost.
      goOnline(current, store: store)
      guard let fresh = entries().first(where: { $0.id == entry.id }), fresh.online else {
        throw StowawayError("couldn't merge \(path) with its copy on the drive; try again")
      }
      current = fresh
    }
    do {
      let remote = try storePath(current.remote, in: store)
      try checkContained(remote, in: store)
      guard isSymlink(path) else { throw StowawayError("\(path) isn't Stowaway's link any more") }
      let staging = Self.leftoverName(for: URL(fileURLWithPath: path), kind: "releasing")
      let stats = try Copier.copyContents(of: remote, into: staging)
      try fm.removeItem(atPath: path)
      try fm.moveItem(at: staging, to: URL(fileURLWithPath: path))
      try trash(remote.deletingLastPathComponent())
      note("brought back \(path): \(stats)")
    }
    save(entries().filter { $0.id != entry.id })
  }

  /// A unique hidden name next to `url` for a copy being set aside (`old`) or put in place
  /// (`releasing`). Unique, so a leftover from an interrupted operation never blocks a later one;
  /// `recover` sweeps leftovers.
  static func leftoverName(for url: URL, kind: String = "old") -> URL {
    url.deletingLastPathComponent().appendingPathComponent(
      ".\(url.lastPathComponent).stowaway-\(kind)-\(UUID().uuidString.prefix(8).lowercased())")
  }

  /// Refuses a path in the store whose folders aren't all real folders: a shared drive could have
  /// had one swapped for a symlink leading elsewhere.
  func checkContained(_ url: URL, in store: URL) throws {
    // Both are built from the same store URL, so compare them as they are (standardizing can
    // rewrite /private/var as /var on one side only). `..` is rejected by `storePath`.
    let base = store.path
    let target = url.path
    guard target == base || target.hasPrefix(base + "/"),
      !target.split(separator: "/").contains("..")
    else {
      throw StowawayError("refusing a path outside the store: \(target)")
    }
    var current = store
    for component in target.dropFirst(base.count).split(separator: "/") {
      current.appendPathComponent(String(component))
      var st = stat()
      guard lstat(current.path, &st) == 0 else { return }  // the rest doesn't exist yet
      if st.st_mode & S_IFMT == S_IFLNK {
        throw StowawayError("refusing a symlink on the drive: \(current.path)")
      }
    }
  }

  /// Deletes an offloaded folder everywhere: the link (or the local folder while the drive is
  /// away) and its copy on the drive. A machine-wide cache folder is left empty rather than
  /// removed, so the permission the user granted for it stays valid.
  public func discard(_ path: String) throws {
    try exclusively {
      guard let entry = entries().first(where: { $0.local == path }) else {
        throw StowawayError("\(path) isn't stowed")
      }
      guard let store = enterGrants() else {
        throw StowawayError("connect the drive to delete \(path)")
      }
      let remote = try storePath(entry.remote, in: store)
      let slot = entry.mode == .packages ? remote : remote.deletingLastPathComponent()
      try checkContained(slot, in: store)
      try trash(slot)
      try trash(URL(fileURLWithPath: path))
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

  /// Re-measures what each stowed folder takes on the drive. Tools keep writing into stowed
  /// folders (a Cargo build into its target, say), so the size recorded when a folder was stowed
  /// falls behind. Measures without the lock, which can take a while, then records the sizes
  /// under it. Does nothing while the drive is away.
  public func recountStowed() {
    guard let store = enterGrants() else { return }
    var sizes: [String: Int64] = [:]
    for entry in entries() where entry.online {
      guard let remote = try? storePath(entry.remote, in: store) else { continue }
      sizes[entry.id] = Measure.allocatedSize(remote.path)
    }
    _ = try? exclusively {
      var all = entries()
      for i in all.indices where all[i].online {
        if let bytes = sizes[all[i].id] { all[i].bytes = bytes }
      }
      save(all)
    }
  }

  /// Before ejecting the drive: every stowed folder becomes a local one, as when it's unplugged,
  /// so nothing on the Mac points at the drive while it unmounts. (Pause the engine meanwhile,
  /// or a reconcile would link them again while the drive is still there.)
  public func prepareForEject() {
    _ = try? exclusively {
      for entry in entries() where entry.online {
        if entry.mode == .packages {
          update(entry.id) { $0.online = false }
        } else {
          goOffline(entry)
        }
      }
    }
  }

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
        // Paused: the local folder stays in use until resumed.
        if paused { continue }
        // Merging a folder a tool is still writing into would lose what it writes meanwhile.
        if isRealDirectory(entry.local), isBeingWritten(entry) { continue }
        goOnline(entry, store: store)
      } else if store == nil, entry.online {
        goOffline(entry)
      } else if let store, entry.online, isLink {
        checkLink(entry, store: store)
      } else if let store, entry.online, !FileManager.default.fileExists(atPath: entry.local) {
        // Interrupted between setting the folder aside and linking it: link it now.
        relink(entry, store: store)
      } else if let store, entry.online, !paused, !isBeingWritten(entry) {
        // A tool replaced the link with a fresh folder (cargo clean, uv venv --clear).
        replace(entry, store: store)
      }
    }
  }

  /// Whether a tool may be writing into an entry's local folder: something in it changed within
  /// `quietPeriod`, or Cargo holds the lock of the build profile it belongs to.
  func isBeingWritten(_ entry: Entry) -> Bool {
    let local = URL(fileURLWithPath: entry.local)
    if entry.kind == .cargoTarget {
      // A part (target/debug/deps) or the whole target: check every profile's lock.
      let target =
        local.lastPathComponent == "target"
        ? local : local.deletingLastPathComponent().deletingLastPathComponent()
      if Measure.isBusy(Candidate(kind: .cargoTarget, path: target.path, project: nil)) {
        return true
      }
    }
    return Date().timeIntervalSince(Self.newestChange(under: local)) <= quietPeriod
  }

  /// A link that doesn't lead to the entry's copy (the drive mounted under another name, or the
  /// copy is gone): point it at the copy, or switch to a local folder if there's none.
  private func checkLink(_ entry: Entry, store: URL) {
    guard let remote = try? storePath(entry.remote, in: store),
      (try? checkContained(remote, in: store)) != nil
    else { return }
    guard isRealDirectory(remote.path) else {
      note("\(entry.local)'s copy on the drive is missing; using a local folder")
      goOffline(entry)
      return
    }
    let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.local)
    if destination != remote.path {
      try? FileManager.default.removeItem(atPath: entry.local)
      relink(entry, store: store)
    }
  }

  /// Puts a folder a tool made in place of the link onto the drive, replacing the old copy
  /// rather than merging into it, so what the tool deleted stays deleted.
  private func replace(_ entry: Entry, store: URL) {
    let fm = FileManager.default
    let local = URL(fileURLWithPath: entry.local)
    do {
      let remote = try storePath(entry.remote, in: store)
      try checkContained(remote, in: store)
      // Copy beside the old copy first; the swap is two renames.
      let staging = Self.leftoverName(for: remote, kind: "staging")
      _ = try Copier.copyContents(of: local, into: staging)
      let old = Self.leftoverName(for: remote)
      if fm.fileExists(atPath: remote.path) { try fm.moveItem(at: remote, to: old) }
      try fm.moveItem(at: staging, to: remote)
      let aside = Self.leftoverName(for: local)
      try fm.moveItem(at: local, to: aside)
      try fm.createSymbolicLink(at: local, withDestinationURL: remote)
      deleteSoon(old)
      deleteSoon(aside)
      let bytes = Measure.allocatedSize(remote.path)
      update(entry.id) { $0.bytes = bytes }
      note("\(entry.local) was replaced by a new folder; it's on the drive in place of the old one")
    } catch {
      note("couldn't move the new \(entry.local) onto the drive: \(error.localizedDescription)")
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
      try checkContained(remote, in: store)
      var stats = CopyStats()
      if isRealDirectory(local.path) {
        stats = try Copier.copyContents(of: local, into: remote)
        let old = Self.leftoverName(for: local)
        try fm.moveItem(at: local, to: old)
        try fm.createSymbolicLink(at: local, withDestinationURL: remote)
        deleteSoon(old)
      } else if !fm.fileExists(atPath: local.path), !isSymlink(local.path) {
        // The project was moved or deleted while the drive was away.
        guard fm.fileExists(atPath: local.deletingLastPathComponent().path) else { return }
        try fm.createSymbolicLink(at: local, withDestinationURL: remote)
      }
      // Recount rather than add: merged files may have replaced ones already counted.
      let bytes = stats.files > 0 ? Measure.allocatedSize(remote.path) : entry.bytes
      update(entry.id) {
        $0.online = true
        $0.bytes = bytes
      }
      note("the drive is back: \(entry.local) is on it again (\(stats))")
    } catch {
      note("couldn't move \(entry.local) back onto the drive: \(error.localizedDescription)")
    }
  }

  private func relink(_ entry: Entry, store: URL) {
    do {
      let remote = try storePath(entry.remote, in: store)
      try checkContained(remote, in: store)
      guard isRealDirectory(remote.path),
        FileManager.default.fileExists(
          atPath: URL(fileURLWithPath: entry.local).deletingLastPathComponent().path)
      else { return }
      try FileManager.default.createSymbolicLink(
        at: URL(fileURLWithPath: entry.local), withDestinationURL: remote)
      note("restored the link at \(entry.local)")
    } catch {
      note("couldn't restore the link at \(entry.local): \(error.localizedDescription)")
    }
  }

  // MARK: Recovery

  /// Finishes or cleans up after operations a quit or crash interrupted. Run at launch.
  ///
  /// Every copy set aside next to an offloaded folder (`.<name>.stowaway-old-…`) or half put in
  /// place (`…stowaway-releasing-…`) is safe to delete while its entry exists: the entry's data
  /// is complete on the drive. npm deep links get their trash swept and any missing links back.
  public func recover() {
    _ = try? exclusively {
      let store = enterGrants()
      finishTrash()
      let fm = FileManager.default
      for entry in entries() {
        let local = URL(fileURLWithPath: entry.local)
        let parent = local.deletingLastPathComponent()
        for name in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
        where name.hasPrefix(".\(local.lastPathComponent).stowaway-old-")
          || name.hasPrefix(".\(local.lastPathComponent).stowaway-releasing-")
        {
          try? Copier.remove(parent.appendingPathComponent(name))
        }
        if entry.mode == .packages, let store {
          recoverPackages(entry, store: store)
        } else if let store, let remote = try? storePath(entry.remote, in: store) {
          recoverReplacement(remote)
        }
      }
      reconcileUnlocked()
    }
  }

  /// After an interrupted `replace`: if the copy is missing, the new one (staging) or else the old
  /// one goes back in its place; whatever's left over is deleted.
  private func recoverReplacement(_ remote: URL) {
    let fm = FileManager.default
    let parent = remote.deletingLastPathComponent()
    let names = (try? fm.contentsOfDirectory(atPath: parent.path)) ?? []
    let staging = names.filter { $0.hasPrefix(".\(remote.lastPathComponent).stowaway-staging-") }
    let old = names.filter { $0.hasPrefix(".\(remote.lastPathComponent).stowaway-old-") }
    if !fm.fileExists(atPath: remote.path), let back = staging.first ?? old.first {
      try? fm.moveItem(at: parent.appendingPathComponent(back), to: remote)
    }
    for name in staging + old where fm.fileExists(atPath: parent.appendingPathComponent(name).path)
    {
      try? Copier.remove(parent.appendingPathComponent(name))
    }
  }

  /// Deletes a folder: in the background when this engine runs in a long-lived process (the
  /// links are already in place, so nothing waits on it), otherwise right away.
  /// Deletes `url` without waiting: renames it aside (instant: same folder, same disk) and
  /// erases it in the background. Erases still pending are recorded, so `recover` finishes them
  /// after a quit or crash. Symlinks aren't followed.
  func trash(_ url: URL) throws {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return }
    // A link or a file goes at once; only folders take time to erase.
    guard st.st_mode & S_IFMT == S_IFDIR else {
      try Copier.remove(url)
      return
    }
    let aside = Self.leftoverName(for: url, kind: "trash")
    try FileManager.default.moveItem(at: url, to: aside)
    lock.withLock {
      defaults.set((defaults.stringArray(forKey: "trash") ?? []) + [aside.path], forKey: "trash")
    }
    let erase: @Sendable () -> Void = { [self] in
      try? Copier.remove(aside)
      lock.withLock {
        defaults.set(
          (defaults.stringArray(forKey: "trash") ?? []).filter { $0 != aside.path }, forKey: "trash"
        )
      }
    }
    if cleanupInBackground {
      DispatchQueue.global(qos: .utility).async(execute: erase)
    } else {
      erase()
    }
  }

  /// Finishes erasing what `trash` set aside before a quit or crash.
  private func finishTrash() {
    let pending = lock.withLock { defaults.stringArray(forKey: "trash") ?? [] }
    for path in pending where path.contains(".stowaway-trash-") {
      try? Copier.remove(URL(fileURLWithPath: path))
    }
    lock.withLock { defaults.removeObject(forKey: "trash") }
  }

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
    return "Stowing this would take you past the free \(format.string(fromByteCount: limit))."
  }
}

public struct StowawayError: LocalizedError, Equatable {
  public let message: String
  /// Whether this folder can't be stowed as it is (git tracks it, it's a pnpm project…), as
  /// opposed to a failure that may pass (the drive went away mid-copy).
  public let isRefusal: Bool
  public init(_ message: String, refusal: Bool = false) {
    self.message = message
    self.isRefusal = refusal
  }
  public static func refusal(_ message: String) -> StowawayError {
    StowawayError(message, refusal: true)
  }
  public var errorDescription: String? { message }
}
