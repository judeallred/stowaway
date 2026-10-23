import Darwin
import Foundation

/// npm-style node_modules support ("deep links").
///
/// npm deletes a symlinked `node_modules`, and replaces a symlinked package folder on every
/// install (it looks like a `link:` dependency). So every package folder stays a real directory
/// and only its *contents* (`dist/`, `package.json`, …) are symlinks into a store on the drive.
/// npm sees ordinary installed packages and `npm install` with nothing to change is as fast as
/// with a local node_modules.
///
/// Node, bundlers and tsc resolve a file to its real path on the drive and look for dependencies
/// from there. In the store each package therefore sits in a private `node_modules/<name>`
/// (so paths still read `…/node_modules/<name>/…`, which tools such as Next.js and babel's
/// `exclude` test for), under directories whose `node_modules` entries link back to the local
/// node_modules folders on the package's resolution chain. Resolution always goes through the
/// local tree npm maintains, so an upgraded dependency is never shadowed by a stale copy.
///
/// npm's hidden lockfile (`node_modules/.package-lock.json`) also moves to the drive. While the
/// drive is here npm reads it and takes its fast path (folder mtimes are preserved so npm trusts
/// it); when the drive is gone it can't, so `npm install` rescans and repairs every package even
/// if Stowaway isn't running.
extension Engine {
  /// Entries npm and other tools own that stay on the Mac.
  static let keepLocal: Set<String> = [
    ".bin", ".cache", ".vite", ".yarn-integrity", ".modules.yaml", ".yarn-state.yml",
  ]
  static let hiddenLockfile = ".package-lock.json"

  // MARK: Guards

  /// Why a project's node_modules can't be stowed (a pnpm project, a Turbopack build without
  /// `turbopack.root`), found without trying: cheap enough to ask while scanning.
  public static func refusal(forNodeModules nodeModules: URL) -> String? {
    packagesRefusal(nodeModules, allowTurbopack: false)
  }

  static func packagesRefusal(_ nodeModules: URL, allowTurbopack: Bool) -> String? {
    let fm = FileManager.default
    let project = nodeModules.deletingLastPathComponent()
    guard nodeModules.lastPathComponent == "node_modules",
      let data = fm.contents(atPath: project.appendingPathComponent("package.json").path),
      let manifest = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    else { return "only a project's node_modules (next to package.json) can be stowed this way" }
    if fm.fileExists(atPath: nodeModules.appendingPathComponent(".pnpm").path)
      || fm.fileExists(atPath: project.appendingPathComponent("pnpm-lock.yaml").path)
    {
      return
        "this is a pnpm project: stow pnpm's store instead (with enableGlobalVirtualStore, node_modules is only links)"
    }
    if !allowTurbopack, usesTurbopack(manifest) {
      return
        "this project builds with Turbopack, which refuses packages outside the project. Set `turbopack.root` in next.config (for example to \"/\"), then stow it with Turbopack allowed"
    }
    return nil
  }

  private static func usesTurbopack(_ manifest: [String: Any]) -> Bool {
    let scripts = (manifest["scripts"] as? [String: String] ?? [:]).values.joined(separator: " ")
    if scripts.contains("--turbopack") || scripts.contains("--turbo ")
      || scripts.hasSuffix("--turbo")
    {
      return true
    }
    let deps = (manifest["dependencies"] as? [String: String] ?? [:])
      .merging(manifest["devDependencies"] as? [String: String] ?? [:]) { a, _ in a }
    // Next.js 16 builds and serves with Turbopack by default.
    if let next = deps["next"], let major = Int(next.drop { !$0.isNumber }.prefix { $0.isNumber }),
      major >= 16
    {
      return true
    }
    return false
  }

  // MARK: Adopting

  /// Offloads an npm-style node_modules package by package. Callers hold the engine's lock and
  /// have validated `local`.
  func adoptPackages(_ local: URL, store: URL, allowTurbopack: Bool) throws -> CopyStats {
    if let refusal = Self.packagesRefusal(local, allowTurbopack: allowTurbopack) {
      throw StowawayError.refusal(refusal)
    }
    let id = String(UUID().uuidString.prefix(8).lowercased())
    let project = local.deletingLastPathComponent().lastPathComponent
    let remoteRel = "\(project)-\(id)"
    var all = entries()
    all.append(
      Entry(
        id: id, local: local.path, remote: remoteRel, online: true, adoptedAt: Date(),
        mode: .packages, kind: .node))
    try save(all)
    let stats: CopyStats
    do {
      stats = try offloadPackages(local: local, store: store.appendingPathComponent(remoteRel))
    } catch {
      // Undo the packages linked so far, as bringing the project back would. If that fails too,
      // the entry stays, so the links keep working and reconcile and recovery can finish.
      if let entry = entries().first(where: { $0.id == id }),
        (try? releasePackages(entry, store: store)) != nil
      {
        try? save(entries().filter { $0.id != id })
      }
      throw error
    }
    update(id) { $0.bytes = stats.bytes }
    note("offloaded \(local.path) package by package: \(stats)")
    return stats
  }

  /// A package folder in node_modules and the local node_modules folders Node searches after the
  /// package's own, nearest first.
  struct Package {
    let path: URL
    let name: String  // `pkg` or `@scope/pkg`
    let chain: [String]
  }

  /// Every package in a node_modules tree, nested ones included.
  static func packages(in nodeModules: URL, chain parentChain: [String]) -> [Package] {
    let fm = FileManager.default
    let chain = [nodeModules.path] + parentChain
    var result: [Package] = []
    func visit(_ dir: URL, name: String) {
      guard isRealDirectory(dir.path) else { return }
      result.append(Package(path: dir, name: name, chain: chain))
      let nested = dir.appendingPathComponent("node_modules")
      if isRealDirectory(nested.path) { result += packages(in: nested, chain: chain) }
    }
    for entry in (try? fm.contentsOfDirectory(atPath: nodeModules.path)) ?? [] {
      if entry.hasPrefix(".") || keepLocal.contains(entry) { continue }
      let url = nodeModules.appendingPathComponent(entry)
      if entry.hasPrefix("@"), isRealDirectory(url.path) {
        for child in (try? fm.contentsOfDirectory(atPath: url.path)) ?? []
        where !child.hasPrefix(".") {
          visit(url.appendingPathComponent(child), name: entry + "/" + child)
        }
      } else {
        visit(url, name: entry)
      }
    }
    return result
  }

  /// The node_modules folders Node searches above a project: every ancestor's, up to `/`.
  static func ancestorChain(of nodeModules: URL) -> [String] {
    var chain: [String] = []
    var dir = nodeModules.deletingLastPathComponent().deletingLastPathComponent()
    while dir.path != "/" {
      chain.append(dir.appendingPathComponent("node_modules").path)
      dir = dir.deletingLastPathComponent()
    }
    return chain
  }

  /// A package's own entries, without its nested node_modules.
  static func contents(of package: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: package.path)) ?? []).filter {
      $0 != "node_modules"
    }
  }

  /// Where an entry links to, if it's a link into `store`.
  static func storeLinkTarget(_ entry: URL, store: URL) -> String? {
    guard let target = try? FileManager.default.destinationOfSymbolicLink(atPath: entry.path),
      isInside(target, store.path)
    else { return nil }
    return target
  }

  /// The slot a package's existing links point into, if any (they all share one).
  static func linkedSlot(of package: URL, store: URL) -> URL? {
    for entry in contents(of: package) {
      if let target = storeLinkTarget(package.appendingPathComponent(entry), store: store),
        let slot = validated(
          URL(fileURLWithPath: target).deletingLastPathComponent().path, in: store),
        isRealDirectory(slot.path)
      {
        return slot
      }
    }
    return nil
  }

  /// Whether every entry of a package (but its nested node_modules) already links into `store`.
  static func isOffloaded(_ package: URL, store: URL) -> Bool {
    contents(of: package).allSatisfy { entry in
      storeLinkTarget(package.appendingPathComponent(entry), store: store) != nil
    }
  }

  /// Moves every package with real contents into the store (or relinks it to an identical copy
  /// already there) and moves npm's hidden lockfile to the drive.
  @discardableResult
  func offloadPackages(local: URL, store: URL) throws -> CopyStats {
    let fm = FileManager.default
    let start = Date()
    var total = CopyStats()
    try fm.createDirectory(at: store, withIntermediateDirectories: true)
    var manifest = Self.readManifest(store)
    var replacedSlots: [URL] = []
    let todo = Self.packages(in: local, chain: Self.ancestorChain(of: local))
      .filter { !Self.contents(of: $0.path).isEmpty && !Self.isOffloaded($0.path, store: store) }

    // npm rewrites unchanged packages too (after an offline install, for example): reuse the copy
    // already in the store when it's identical. Compare in parallel.
    let reuse = NameSet()
    let known = manifest
    DispatchQueue.concurrentPerform(iterations: todo.count) { i in
      let rel = Self.relative(todo[i].path, to: local)
      if let target = known[rel].flatMap({ Self.validated($0, in: store) }),
        Self.sameTree(todo[i].path, target)
      {
        reuse.insert(rel)
      }
    }
    let compared = Date()

    let trash = local.appendingPathComponent(".stowaway-trash-\(UUID().uuidString.prefix(8))")
    if !todo.isEmpty { try fm.createDirectory(at: trash, withIntermediateDirectories: false) }
    for (i, package) in todo.enumerated() {
      let rel = Self.relative(package.path, to: local)
      // Only entries that are still real files move; links already pointing into the store stay.
      let real = Self.contents(of: package.path).filter {
        Self.storeLinkTarget(package.path.appendingPathComponent($0), store: store) == nil
      }
      let target: URL
      if let slot = Self.linkedSlot(of: package.path, store: store) {
        // Partly linked already (a native build added files): add the new ones to the same slot.
        try checkContained(slot, in: store)
        let stats = try Self.copyContents(of: package.path, names: real, into: slot)
        total.files += stats.files
        total.bytes += stats.bytes
        target = slot
      } else if reuse.contains(rel),
        let existing = manifest[rel].flatMap({ Self.validated($0, in: store) })
      {
        try checkContained(existing, in: store)
        target = existing
        total.reused += 1
      } else {
        target = try Self.makeSlot(
          in: store, name: package.name, chain: package.chain, package: package.path)
        let stats = try Self.copyContents(of: package.path, names: real, into: target)
        total.files += stats.files
        total.directories += stats.directories
        total.bytes += stats.bytes
        // An upgraded package gets a new slot; the old one is deleted once the links move.
        if let previous = manifest[rel].flatMap({ Self.validated($0, in: store) }) {
          replacedSlots.append(previous)
        }
        manifest[rel] = target.path
      }
      // Swap each entry for a link, keeping the folder's mtime so npm's lockfile stays trusted.
      var st = stat()
      lstat(package.path.path, &st)
      let aside = trash.appendingPathComponent("\(i)")
      try fm.createDirectory(at: aside, withIntermediateDirectories: false)
      // Whose files these are, written first: after a crash between moving an entry aside and
      // linking it, `recoverPackages` puts it back.
      try Data(package.path.path.utf8).write(
        to: trash.appendingPathComponent("\(i)\(Self.asideOwnerSuffix)"))
      for entry in real {
        let source = package.path.appendingPathComponent(entry)
        try fm.moveItem(at: source, to: aside.appendingPathComponent(entry))
        try fm.createSymbolicLink(
          at: source, withDestinationURL: target.appendingPathComponent(entry))
      }
      Self.setTimes(package.path, from: st)
    }
    let swapped = Date()
    try Self.writeManifest(manifest, to: store)
    for slot in replacedSlots { removeSlot(slot, in: store) }
    try moveLockfile(local: local, store: store)
    if !todo.isEmpty { deleteSoon(trash) }
    total.seconds = Date().timeIntervalSince(start)
    logger.debug(
      "re-offload timing: compare \(compared.timeIntervalSince(start)) s, copy and swap \(swapped.timeIntervalSince(compared)) s"
    )
    return total
  }

  /// Creates `<store>/<id>/d/…/node_modules/<name>` with one `node_modules` link per level back to
  /// the local chain, and a link from the slot's own node_modules to the package's local one.
  static func makeSlot(in store: URL, name: String, chain: [String], package: URL) throws -> URL {
    let fm = FileManager.default
    var level = store.appendingPathComponent(UUID().uuidString.prefix(12).lowercased())
    var levels = [level]
    for _ in chain.indices {
      level = level.appendingPathComponent("d")
      levels.append(level)
    }
    let target = level.appendingPathComponent("node_modules").appendingPathComponent(name)
    try fm.createDirectory(at: target, withIntermediateDirectories: true)
    // Walking up from the private node_modules: levels[k-1]/node_modules → chain[0], …
    for (depth, path) in chain.enumerated() {
      try fm.createSymbolicLink(
        at: levels[chain.count - 1 - depth].appendingPathComponent("node_modules"),
        withDestinationURL: URL(fileURLWithPath: path))
    }
    try fm.createSymbolicLink(
      at: target.appendingPathComponent("node_modules"),
      withDestinationURL: package.appendingPathComponent("node_modules"))
    return target
  }

  /// Copies the named entries of a package (never its nested node_modules) into its slot.
  static func copyContents(of package: URL, names: [String], into target: URL) throws -> CopyStats {
    var total = CopyStats()
    for entry in names where entry != "node_modules" {
      let source = package.appendingPathComponent(entry)
      let destination = target.appendingPathComponent(entry)
      if isRealDirectory(source.path) {
        let stats = try Copier.copyContents(of: source, into: destination)
        total.files += stats.files
        total.directories += stats.directories
        total.bytes += stats.bytes
      } else {
        // Replace whatever is there without following it (it may be a link on a shared drive).
        if isRealDirectory(destination.path) {
          try Copier.remove(destination)
        } else {
          unlink(destination.path)
        }
        if copyfile(
          source.path, destination.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW))
          != 0
        {
          throw StowawayError("copying \(source.path): \(String(cString: strerror(errno)))")
        }
        total.files += 1
      }
    }
    return total
  }

  /// Keeps npm's hidden lockfile on the drive (see the type comment), preserving its mtime and
  /// node_modules' so npm still trusts it.
  func moveLockfile(local: URL, store: URL) throws {
    let fm = FileManager.default
    let lockfile = local.appendingPathComponent(Self.hiddenLockfile)
    var st = stat()
    guard lstat(lockfile.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return }
    var dirStat = stat()
    lstat(local.path, &dirStat)
    let remote = store.appendingPathComponent("hidden-lockfile.json")
    // Not following links: the drive isn't trusted, and one planted there could lead elsewhere.
    unlink(remote.path)
    guard
      copyfile(lockfile.path, remote.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW))
        == 0
    else {
      throw StowawayError("copying \(lockfile.path): \(String(cString: strerror(errno)))")
    }
    Self.setTimes(remote, from: st)
    try fm.removeItem(at: lockfile)
    try fm.createSymbolicLink(at: lockfile, withDestinationURL: remote)
    Self.setTimes(local, from: dirStat)
  }

  // MARK: Helpers

  /// A manifest target as a URL, if it's inside `store`. The manifest lives on the drive, which may
  /// be shared, so its paths aren't trusted.
  static func validated(_ target: String, in store: URL) -> URL? {
    guard !target.split(separator: "/").contains(".."), isInside(target, store.path) else {
      return nil
    }
    // Rebuild it from the store's own URL, so later checks compare like with like.
    let base = canonicalPath(store.path)
    return store.appendingPathComponent(String(canonicalPath(target).dropFirst(base.count + 1)))
  }

  static func setTimes(_ url: URL, from st: stat) {
    var times = [st.st_atimespec, st.st_mtimespec]
    utimensat(AT_FDCWD, url.path, &times, AT_SYMLINK_NOFOLLOW)
  }

  static func relative(_ url: URL, to base: URL) -> String {
    String(url.path.dropFirst(base.path.count + 1))
  }

  static func readManifest(_ store: URL) -> [String: String] {
    guard
      let data = FileManager.default.contents(
        atPath: store.appendingPathComponent("manifest.json").path)
    else { return [:] }
    return (try? JSONDecoder().decode([String: String].self, from: data)) ?? [:]
  }

  static func writeManifest(_ manifest: [String: String], to store: URL) throws {
    try JSONEncoder().encode(manifest).write(
      to: store.appendingPathComponent("manifest.json"), options: .atomic)
  }

  /// Whether node_modules has been untouched for `quietPeriod` (an install isn't running).
  func isQuiet(_ local: URL) -> Bool {
    var newest = Self.topLevelChange(local)
    if Date().timeIntervalSince(newest) <= quietPeriod { return false }
    // Packages with real files may still be being written (a postinstall compiling for minutes
    // touches only its own folder): look inside those too.
    for package in Self.packages(in: local, chain: [])
    where Self.contents(of: package.path).contains(where: {
      !isSymlink(package.path.appendingPathComponent($0).path)
    }) {
      newest = max(newest, Self.newestChange(under: package.path))
    }
    return Date().timeIntervalSince(newest) > quietPeriod
  }

  /// When node_modules last changed as a whole: its own date and npm's hidden lockfile (which
  /// npm rewrites on every install, and other package managers' installs add or remove
  /// entries, which dates the folder). Two lstat calls, cheap enough for every reconcile.
  static func installChange(_ local: URL) -> Date {
    var newest = Date.distantPast
    for path in [local.path, local.appendingPathComponent(hiddenLockfile).path] {
      var st = stat()
      if lstat(path, &st) == 0 {
        newest = max(
          newest,
          Date(
            timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
              + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9))
      }
    }
    return newest
  }

  /// The newest change at node_modules' top level: the folder, its entries (the hidden lockfile
  /// among them) and its scoped folders' entries. Cheap: no package is opened.
  static func topLevelChange(_ local: URL) -> Date {
    var newest = Date.distantPast
    let fm = FileManager.default
    var dirs = [local.path]
    for name in (try? fm.contentsOfDirectory(atPath: local.path)) ?? [] where name.hasPrefix("@") {
      dirs.append(local.path + "/" + name)
    }
    for dir in dirs {
      for name in [""] + ((try? fm.contentsOfDirectory(atPath: dir)) ?? []) {
        var st = stat()
        if lstat(name.isEmpty ? dir : dir + "/" + name, &st) == 0 {
          newest = max(
            newest,
            Date(
              timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)
                + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9))
        }
      }
    }
    return newest
  }

  /// The newest modification time of anything under `root`, not following links.
  static func newestChange(under root: URL) -> Date {
    var newest = Date.distantPast
    var paths: [UnsafeMutablePointer<CChar>?] = [strdup(root.path), nil]
    defer { free(paths[0]) }
    guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return newest }
    defer { fts_close(fts) }
    while let entry = fts_read(fts) {
      if let st = entry.pointee.fts_statp {
        newest = max(
          newest, Date(timeIntervalSince1970: TimeInterval(st.pointee.st_mtimespec.tv_sec)))
      }
    }
    return newest
  }

  // MARK: Comparing

  /// Whether two package folders hold the same files (ignoring their nested node_modules): the
  /// same package.json and the same file names, sizes and modification times. npm sets file
  /// times from the package tarball, so an identical reinstall matches.
  static func sameTree(_ a: URL, _ b: URL) -> Bool {
    guard let x = fingerprint(a), let y = fingerprint(b), !x.manifests.isEmpty else { return false }
    return x.files == y.files && x.bytes == y.bytes && x.manifests == y.manifests
      && x.listing == y.listing
  }

  /// Counts files and bytes under `root` with fts (as fast as `find`), skipping its nested
  /// node_modules, and keeps its package.json.
  static func fingerprint(_ root: URL) -> (
    files: Int, bytes: Int64, manifests: [String: Data], listing: [String]
  )? {
    var listing: [String] = []
    var files = 0
    var bytes: Int64 = 0
    var manifests: [String: Data] = [:]
    let rootPath = root.path
    var paths: [UnsafeMutablePointer<CChar>?] = [strdup(rootPath), nil]
    defer { free(paths[0]) }
    guard let fts = fts_open(&paths, FTS_PHYSICAL | FTS_NOCHDIR, nil) else { return nil }
    defer { fts_close(fts) }
    while let entry = fts_read(fts) {
      let path = String(cString: entry.pointee.fts_path)
      if entry.pointee.fts_level == 1, path.hasSuffix("/node_modules") {
        fts_set(fts, entry, FTS_SKIP)
        continue
      }
      switch Int32(entry.pointee.fts_info) {
      case FTS_F, FTS_SL, FTS_SLNONE, FTS_DEFAULT:
        files += 1
        let st = entry.pointee.fts_statp.pointee
        bytes += Int64(st.st_size)
        listing.append("\(path.dropFirst(rootPath.count)) \(st.st_size) \(st.st_mtimespec.tv_sec)")
        if entry.pointee.fts_level == 1, path.hasSuffix("/package.json") {
          manifests["package.json"] = FileManager.default.contents(atPath: path)
        }
      case FTS_DNR, FTS_ERR, FTS_NS:
        return nil
      default:
        break
      }
    }
    return (files, bytes, manifests, listing.sorted())
  }

  // MARK: The drive coming and going

  func reconcilePackages(_ entry: Entry, store mine: URL?) {
    let fm = FileManager.default
    let local = URL(fileURLWithPath: entry.local)
    guard fm.fileExists(atPath: local.path) else { return }
    guard let mine, let store = try? storePath(entry.remote, in: mine) else {
      // Nothing to undo: the links dangle, npm can't read its lockfile, so `npm install` rescans
      // and repairs every package locally.
      if entry.online {
        update(entry.id) { $0.online = false }
        note("offline: \(entry.local) will be rebuilt locally by the next npm install")
      }
      return
    }
    // The drive isn't trusted: a store that's been swapped for a link is left alone.
    guard (try? checkContained(store, in: mine)) != nil else {
      note("\(store.path) isn't inside Stowaway's store; leaving \(entry.local) alone")
      return
    }
    // Paused: the links work again with the drive back; re-stowing waits.
    if paused {
      if !entry.online { update(entry.id) { $0.online = true } }
      return
    }
    // npm can only have changed the tree by changing its top level (it rewrites the hidden
    // lockfile on every install), so a settled project whose top level hasn't moved is skipped.
    let before = Self.installChange(local)
    if entry.online, settledChange(of: entry.id) == before { return }
    var st = stat()
    let lockfile = local.appendingPathComponent(Self.hiddenLockfile).path
    let lockfileIsLocal = lstat(lockfile, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
    let pending = Self.packages(in: local, chain: Self.ancestorChain(of: local))
      .filter { !Self.contents(of: $0.path).isEmpty && !Self.isOffloaded($0.path, store: store) }
    if !pending.isEmpty || lockfileIsLocal {
      guard isQuiet(local) else { return }  // an install may still be running
      do {
        let stats = try offloadPackages(local: local, store: store)
        if !pending.isEmpty {
          note("re-offloaded \(pending.count) packages in \(entry.local): \(stats)")
        }
      } catch {
        note("couldn't re-offload \(entry.local): \(error.localizedDescription)")
        return
      }
    }
    if !entry.online {
      update(entry.id) { $0.online = true }
      note("online: \(entry.local) packages on the drive again")
    }
    if isQuiet(local) {
      pruneStore(local: local, store: store)
      setSettledChange(Self.installChange(local), of: entry.id)
    }
  }

  /// Deletes package copies in the store that no local package uses any more.
  private func pruneStore(local: URL, store: URL) {
    var manifest = Self.readManifest(store)
    let live = Set(Self.packages(in: local, chain: []).map { Self.relative($0.path, to: local) })
    var removed = 0
    for (rel, target) in manifest where !live.contains(rel) {
      // A slot is the first folder under the store. The manifest lives on the drive, so a target
      // outside the store is dropped, never deleted.
      if let target = Self.validated(target, in: store) { removeSlot(target, in: store) }
      manifest[rel] = nil
      removed += 1
    }
    if removed > 0 { try? Self.writeManifest(manifest, to: store) }
  }

  /// Deletes the slot a package's copy lives in: the first folder under the store.
  private func removeSlot(_ target: URL, in store: URL) {
    let slot = String(target.path.dropFirst(store.path.count + 1).prefix { $0 != "/" })
    let url = store.appendingPathComponent(slot)
    if !slot.isEmpty, (try? checkContained(url, in: store)) != nil { try? trash(url) }
  }

  /// After an interrupted re-offload: deletes the trash (its contents are already on the drive)
  /// and restores links that were set aside but not yet created.
  /// Marks the file naming the package an aside folder's entries came from.
  static let asideOwnerSuffix = ".package"

  /// Puts back what an interrupted re-offload moved aside but hadn't linked yet: anything in the
  /// trash whose place in its package is empty. Entries already linked stay linked (their copy
  /// in the store is complete).
  static func restoreAside(in trash: URL, local: URL) {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: trash.path)) ?? []
    where name.hasSuffix(asideOwnerSuffix) {
      guard
        let path = try? String(contentsOf: trash.appendingPathComponent(name), encoding: .utf8),
        path.hasPrefix(local.path + "/")
      else { continue }
      let package = URL(fileURLWithPath: path)
      let aside = trash.appendingPathComponent(String(name.dropLast(asideOwnerSuffix.count)))
      for entry in (try? fm.contentsOfDirectory(atPath: aside.path)) ?? [] {
        let original = package.appendingPathComponent(entry)
        var st = stat()
        if lstat(original.path, &st) != 0 {
          try? fm.moveItem(at: aside.appendingPathComponent(entry), to: original)
        }
      }
    }
  }

  func recoverPackages(_ entry: Entry, store mine: URL) {
    let fm = FileManager.default
    let local = URL(fileURLWithPath: entry.local)
    for name in (try? fm.contentsOfDirectory(atPath: local.path)) ?? []
    where name.hasPrefix(".stowaway-trash-") {
      let trash = local.appendingPathComponent(name)
      Self.restoreAside(in: trash, local: local)
      try? Copier.remove(trash)
    }
    // An interrupted release leaves `.<name>.stowaway-releasing-…` copies in package folders:
    // one whose original is gone goes back in its place; the rest are deleted.
    for package in Self.packages(in: local, chain: []) {
      for name in (try? fm.contentsOfDirectory(atPath: package.path.path)) ?? [] {
        guard name.hasPrefix("."), let marker = name.range(of: ".stowaway-releasing-") else {
          continue
        }
        let staging = package.path.appendingPathComponent(name)
        let original = package.path.appendingPathComponent(
          String(name[name.index(after: name.startIndex)..<marker.lowerBound]))
        var st = stat()
        if lstat(original.path, &st) != 0 {
          try? fm.moveItem(at: staging, to: original)
        } else {
          try? Copier.remove(staging)
        }
      }
    }
    guard let store = try? storePath(entry.remote, in: mine),
      (try? checkContained(store, in: mine)) != nil
    else { return }
    for (rel, target) in Self.readManifest(store) {
      let package = local.appendingPathComponent(rel)
      guard let slot = Self.validated(target, in: store),
        (try? checkContained(slot, in: store)) != nil,
        isRealDirectory(package.path), Self.linkedSlot(of: package, store: store)?.path == slot.path
      else { continue }
      for name in (try? fm.contentsOfDirectory(atPath: slot.path)) ?? []
      where name != "node_modules" {
        let path = package.appendingPathComponent(name)
        var st = stat()
        if lstat(path.path, &st) != 0 {
          try? fm.createSymbolicLink(
            at: path, withDestinationURL: slot.appendingPathComponent(name))
        }
      }
    }
  }

  // MARK: Releasing

  func releasePackages(_ entry: Entry, store mine: URL?) throws {
    let fm = FileManager.default
    let local = URL(fileURLWithPath: entry.local)
    guard let mine else {
      throw StowawayError("connect the drive to bring \(entry.local) back")
    }
    let store = try storePath(entry.remote, in: mine)
    // Check every link first, then copy in parallel (one file at a time took minutes for a big
    // project), then swap each copy in for its link.
    var jobs: [(path: URL, target: String, staging: URL)] = []
    var times: [(URL, stat)] = []
    for package in Self.packages(in: local, chain: []) {
      var st = stat()
      lstat(package.path.path, &st)
      times.append((package.path, st))
      for name in Self.contents(of: package.path) {
        let path = package.path.appendingPathComponent(name)
        guard let link = Self.storeLinkTarget(path, store: store) else {
          // A link that leads nowhere may be to this store under another name (the drive mounted
          // differently): its contents would be lost with the store, so stop.
          if isSymlink(path.path), !FileManager.default.fileExists(atPath: path.path) {
            throw StowawayError(
              "\(path.path) links to something that isn't there; connect the drive as before to bring it back"
            )
          }
          continue
        }
        // Follow chains only within the store (an older release could have left one), and refuse
        // anything else: the drive isn't trusted.
        let target = canonicalPath(link)
        guard isInside(target, store.path), !isSymlink(target) else {
          throw StowawayError(
            "\(path.path) links to \(link), outside Stowaway's store; leaving it alone")
        }
        jobs.append((path, target, Self.leftoverName(for: path, kind: "releasing")))
      }
    }
    let failure = Failure()
    let work = jobs
    DispatchQueue.concurrentPerform(iterations: Copier.workers) { worker in
      var i = worker
      while i < work.count, !failure.isSet {
        let job = work[i]
        if isRealDirectory(job.target) {
          do {
            _ = try Copier.copyContents(of: URL(fileURLWithPath: job.target), into: job.staging)
          } catch {
            failure.set(error)
          }
        } else if copyfile(
          job.target, job.staging.path, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW))
          != 0
        {
          failure.set(StowawayError("copying \(job.target): \(String(cString: strerror(errno)))"))
        }
        i += Copier.workers
      }
    }
    if let error = failure.error {
      for job in jobs { try? Copier.remove(job.staging) }
      throw error
    }
    for job in jobs {
      try fm.removeItem(at: job.path)
      try fm.moveItem(at: job.staging, to: job.path)
    }
    for (folder, st) in times { Self.setTimes(folder, from: st) }
    let lockfile = local.appendingPathComponent(Self.hiddenLockfile)
    if let target = Self.storeLinkTarget(lockfile, store: store) {
      var dirStat = stat()
      lstat(local.path, &dirStat)
      try fm.removeItem(at: lockfile)
      _ = copyfile(target, lockfile.path, nil, copyfile_flags_t(COPYFILE_ALL))
      Self.setTimes(local, from: dirStat)
    }
    try checkContained(store, in: mine)
    try trash(store)
    note("released \(entry.local)")
  }
}

private final class NameSet: @unchecked Sendable {
  private let lock = NSLock()
  private var names: Set<String> = []
  func insert(_ name: String) { lock.withLock { _ = names.insert(name) } }
  func contains(_ name: String) -> Bool { lock.withLock { names.contains(name) } }
}
