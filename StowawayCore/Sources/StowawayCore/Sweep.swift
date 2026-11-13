import Darwin
import Foundation

/// How a sweep goes about it. The defaults suit the app; tests make files count at once.
public struct SweepOptions: Sendable {
  /// Smaller files aren't worth the bookkeeping: most of the space is in big ones.
  public var minimumSize: Int64 = 64 * 1024
  /// Only files unchanged for this long are touched: a tool may still be writing one.
  public var minimumAge: TimeInterval = 600
  /// Reads at the lowest disk priority, so builds and stowing go first. Off when the drive is
  /// nearly full and getting space back matters more.
  public var lowPriority = true
  /// Longest the engine's lock is held at a time while clones are swapped in, so stowing and
  /// reconciling never wait long.
  public var lockSlice: TimeInterval = 0.2
  /// A sweep stopped to make way picks up where it was, without walking the drive again, if
  /// the last walk finished this recently. (Reading and sharing check every file anyway.)
  public var rewalkAfter: TimeInterval = 10 * 60

  public init() {}
}

/// What a sweep did.
public struct SweepReport: Sendable, Equatable {
  public enum Outcome: Sendable, Equatable {
    /// Every file was looked at.
    case finished
    /// It stopped early for other work; the next sweep carries on.
    case yielded
    /// The drive's format can't share files (only APFS can).
    case unsupported
    /// No drive, paused, or the index couldn't be opened.
    case unavailable
    /// Another sweep is running.
    case busy
  }

  public var outcome: Outcome
  public var filesSeen = 0
  public var filesHashed = 0
  public var bytesHashed: Int64 = 0
  public var filesShared = 0
  /// Space this sweep saved.
  public var bytesSaved: Int64 = 0

  public init(outcome: Outcome) { self.outcome = outcome }
}

/// How far a sweep has got, for the status line.
public enum SweepProgress: Sendable, Equatable {
  /// Noting the drive's files: this many so far.
  case walking(files: Int)
  /// Reading files that may have a twin: bytes read of those to read.
  case reading(bytes: Int64, of: Int64)
  /// Swapping duplicates for clones: files done of those to do.
  case sharing(files: Int, of: Int)
}

/// Passes progress on at most twice a second (and always the first time).
final class Progress: @unchecked Sendable {
  private let report: @Sendable (SweepProgress) -> Void
  private var last = Date.distantPast

  init(_ report: @escaping @Sendable (SweepProgress) -> Void) { self.report = report }

  func report(_ progress: SweepProgress, force: Bool = false) {
    let now = Date()
    guard force || now.timeIntervalSince(last) >= 0.5 else { return }
    last = now
    report(progress)
  }
}

extension Engine {
  // MARK: The index

  /// What tells one store from another: the volume (a reformatted or different drive is another
  /// one) and the store's path.
  static func storeIdentity(_ store: URL) -> String {
    let volume = (try? store.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString
    return "\(volume ?? "?"):\(store.path)"
  }

  /// The index for `store`, opened once. Nil where files can't be shared.
  func sharedIndex(for store: URL) -> SharedIndex? {
    let identity = Self.storeIdentity(store)
    return sharedIndexLock.withLock {
      if let open = openSharedIndex, open.identity == identity { return open.index }
      guard Cloning.volumeSupportsCloning(store) else { return nil }
      openSharedIndex = nil
      let url = stateDirectory.appendingPathComponent("shared-files.sqlite")
      guard let index = try? SharedIndex(at: url, identity: identity) else { return nil }
      openSharedIndex = (identity, index)
      return index
    }
  }

  /// Space saved on the drive by sharing identical files, as last worked out (it's known while
  /// the drive is away too). Cheap: the sum is worked out when sharing changes, not here.
  public func savedBySharing() -> Int64 {
    Int64(defaults.integer(forKey: "savedBySharing"))
  }

  /// Works out the space saved again, after files were shared, copied or forgotten.
  func updateSavedBySharing(_ index: SharedIndex) {
    if let bytes = try? index.savedBytes() { defaults.set(bytes, forKey: "savedBySharing") }
  }

  /// After a copy cloned files: the space saved grew.
  func sharingChanged(_ store: URL) {
    if let index = sharedIndex(for: store) { updateSavedBySharing(index) }
  }

  /// Forgets what the index knew about a folder in the store (deleted, brought back, replaced).
  func forgetShared(_ relative: String, store: URL) {
    guard let index = sharedIndex(for: store) else { return }
    try? index.forget(relative)
    updateSavedBySharing(index)
  }

  /// Clones, rather than copies, files the drive already has. Nil where files can't be shared.
  func cloneSource(for store: URL) -> StoreClones? {
    guard let index = sharedIndex(for: store) else { return nil }
    return StoreClones(index: index, store: store.path)
  }

  // MARK: Sweeping

  /// Finds identical files on the drive and makes them share their storage, a step at a time:
  ///
  /// 1. **Walk** every stowed folder on the drive, noting each file's stamp. Nothing is read.
  ///    Files the index already knows, unchanged, cost nothing more.
  /// 2. **Read** (hash) only files whose size another file has, biggest first.
  /// 3. **Share**: for each hash with files not sharing yet, clone one that is (or the first)
  ///    over each of the others, in short turns with the engine's lock.
  ///
  /// It skips anything changed in the last `minimumAge`, folders a Cargo build holds, and
  /// Stowaway's own work in progress. `shouldYield` is asked between files; once it says yes the
  /// sweep stops, and the next one picks up from what the index has. Never runs while paused.
  public func sweepSharedFiles(
    _ options: SweepOptions = SweepOptions(), shouldYield: @Sendable () -> Bool = { false },
    progress report: @escaping @Sendable (SweepProgress) -> Void = { _ in }
  ) -> SweepReport {
    let progress = Progress(report)
    guard sweepLock.try() else { return SweepReport(outcome: .busy) }
    defer { sweepLock.unlock() }
    // Pausing (as an eject does) stops it too, whatever the caller says.
    let shouldYield = { self.paused || shouldYield() }
    guard !paused, let store = enterGrants() else { return SweepReport(outcome: .unavailable) }
    guard Cloning.volumeSupportsCloning(store) else { return SweepReport(outcome: .unsupported) }
    guard let index = sharedIndex(for: store) else { return SweepReport(outcome: .unavailable) }
    if options.lowPriority {
      setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_THROTTLE)
    }
    defer {
      if options.lowPriority { setiopolicy_np(IOPOL_TYPE_DISK, IOPOL_SCOPE_THREAD, IOPOL_DEFAULT) }
      updateSavedBySharing(index)
    }
    var report = SweepReport(outcome: .finished)
    let lastWalk = (try? index.meta("walked")).flatMap { $0.flatMap(Double.init) } ?? 0
    var finished = true
    if Date().timeIntervalSince1970 - lastWalk >= options.rewalkAfter {
      progress.report(.walking(files: 0), force: true)
      finished = walk(store, index, options, &report, shouldYield, progress)
      if finished { try? index.setMeta("walked", String(Date().timeIntervalSince1970)) }
    }
    if finished { finished = hashTwins(store, index, options, &report, shouldYield, progress) }
    if finished { finished = shareTwins(store, index, options, &report, shouldYield, progress) }
    guard finished else {
      report.outcome = .yielded
      return report
    }
    note(
      "shared identical files: \(report.filesShared) files, \(ByteCountFormatter.string(fromByteCount: report.bytesSaved, countStyle: .file)) saved"
    )
    return report
  }

  /// Brings the index up to date with every stowed folder on the drive. Only what changed is
  /// written: files new or changed since are noted (unread), and files gone (or no longer worth
  /// sharing) are forgotten. Memory stays flat however big a folder is: each file is looked up on
  /// its own, and what the index knows is checked against the drive a page at a time. False if
  /// it stopped early (what it did so far stands).
  private func walk(
    _ store: URL, _ index: SharedIndex, _ options: SweepOptions, _ report: inout SweepReport,
    _ shouldYield: () -> Bool, _ progress: Progress
  ) -> Bool {
    let base = store.path
    var leftovers: [String] = []
    var folders: Set<String> = []
    var counted = 0
    for entry in entries() {
      guard let remote = try? storePath(entry.remote, in: store),
        (try? checkContained(remote, in: store)) != nil
      else { continue }
      let folder = String(remote.path.dropFirst(base.count + 1))
      folders.insert(folder)
      // A tool writing into it right now: leave it (and what's known of it) for another time.
      // Not the shared Cargo build folder: every build writes there, so it'd hardly ever be
      // swept. Its profiles' locks, and files' age, keep builds' files alone instead.
      if entry.online, entry.kind != .cargoBuild, isBeingWritten(entry) { continue }
      var roots: [UnsafeMutablePointer<CChar>?] = [strdup(remote.path), nil]
      defer { free(roots[0]) }
      guard let fts = fts_open(&roots, FTS_PHYSICAL | FTS_NOCHDIR | FTS_XDEV, nil) else {
        continue
      }
      defer { fts_close(fts) }
      do {
        try index.batch {
          while let item = fts_read(fts) {
            let info = Int32(item.pointee.fts_info)
            let path = String(cString: item.pointee.fts_path)
            let name = (path as NSString).lastPathComponent
            if info == FTS_D {
              // Stowaway's own work in progress (staging, set aside, trash), and folders a
              // Cargo build holds right now (the shared build folder's profiles are on the
              // drive): skipped, what's known there stands.
              if (name.hasPrefix(".") && name.contains(".stowaway-"))
                || isLockedCargoProfile(path)
              {
                fts_set(fts, item, FTS_SKIP)
              }
              continue
            }
            guard info == FTS_F, let st = item.pointee.fts_statp?.pointee else { continue }
            if name.hasPrefix(Cloning.temporaryPrefix) {
              leftovers.append(path)
              continue
            }
            if name.hasPrefix("."), name.contains(".stowaway-") { continue }
            guard Int64(st.st_size) >= options.minimumSize, isShareable(st) else { continue }
            report.filesSeen += 1
            let rel = String(path.dropFirst(base.count + 1))
            let stamp = FileStamp(st)
            if try index.row(rel)?.stamp != stamp {
              try index.put(SharedIndex.Row(path: rel, stamp: stamp))
            }
            counted += 1
            if counted % 1000 == 0 {
              progress.report(.walking(files: counted))
              if shouldYield() { throw Yielded() }
            }
          }
        }
      } catch {
        return false
      }
      // What the index knows there, checked against the drive: whatever isn't there any more
      // (or is no longer worth sharing) is forgotten. Files the walk skipped are still there.
      var after: String?
      while let page = try? index.rows(in: folder, after: after, limit: 2000), !page.isEmpty {
        if shouldYield() { return false }
        try? index.batch {
          for row in page {
            var st = stat()
            if lstat(base + "/" + row.path, &st) != 0 || Int64(st.st_size) < options.minimumSize
              || !isShareable(st)
            {
              try index.forget(row.path)
            }
          }
        }
        after = page.last?.path
      }
    }
    // Folders no longer stowed (deleted or brought back while the app was away).
    for top in (try? index.topFolders()) ?? []
    where !folders.contains(where: { $0 == top || $0.hasPrefix(top + "/") }) {
      try? index.forget(top)
    }
    // Clones a crash left half made: never swapped in, so nothing refers to them.
    if !leftovers.isEmpty {
      _ = try? exclusively {
        for path in leftovers
        where (path as NSString).lastPathComponent.hasPrefix(Cloning.temporaryPrefix) {
          unlink(path)
        }
      }
    }
    return true
  }

  /// Reads files that may have a twin (another file has their size). False if it stopped early.
  private func hashTwins(
    _ store: URL, _ index: SharedIndex, _ options: SweepOptions, _ report: inout SweepReport,
    _ shouldYield: () -> Bool, _ progress: Progress
  ) -> Bool {
    let quietSince = Date().addingTimeInterval(-options.minimumAge)
    let toRead = (try? index.bytesToRead()) ?? 0
    var read: Int64 = 0
    if toRead > 0 { progress.report(.reading(bytes: 0, of: toRead), force: true) }
    var lastRead: SharedIndex.Row?
    var rows = ((try? index.unhashedWithTwins()) ?? [])[...]
    var stopped = false
    while !stopped {
      if rows.isEmpty {
        // The next page, after the last one: files left unread (too new) aren't met again.
        guard let last = lastRead,
          let next = try? index.unhashedWithTwins(after: last), !next.isEmpty
        else { break }
        rows = next[...]
      }
      // Asked between files, but written to the index a few hundred at a time.
      var hashed: [(Data, FileStamp, String)] = []
      var gone: [String] = []
      var bytes: Int64 = 0
      while let row = rows.first, hashed.count + gone.count < 256 {
        if shouldYield() {
          stopped = true
          break
        }
        rows.removeFirst()
        lastRead = row
        guard row.stamp.changedDate <= quietSince else { continue }
        if let (hash, stamp) = Cloning.hash(store.path + "/" + row.path, expected: row.stamp) {
          hashed.append((hash, stamp, row.path))
          bytes += stamp.size
          read += stamp.size
          progress.report(.reading(bytes: read, of: toRead))
        } else {
          // Gone or changed: the next walk notes it as it is now.
          gone.append(row.path)
        }
      }
      try? index.batch {
        for (hash, stamp, path) in hashed {
          try index.put(SharedIndex.Row(path: path, stamp: stamp, hash: hash))
        }
        for path in gone { try index.forget(path) }
      }
      report.filesHashed += hashed.count
      report.bytesHashed += bytes
    }
    if stopped { return false }
    return true
  }

  /// One file to swap for a clone of its twin.
  private struct Swap {
    let duplicate: SharedIndex.Row
    let keeper: SharedIndex.Row
  }

  /// Swaps each file not yet sharing for a clone of its twin, in short turns with the engine's
  /// lock (several hashes a turn), so stowing and reconciling never wait long. False if it
  /// stopped early.
  private func shareTwins(
    _ store: URL, _ index: SharedIndex, _ options: SweepOptions, _ report: inout SweepReport,
    _ shouldYield: () -> Bool, _ progress: Progress
  ) -> Bool {
    let toShare = (try? index.filesToShare()) ?? 0
    if toShare > 0 { progress.report(.sharing(files: 0, of: toShare), force: true) }
    let quietSince = Date().addingTimeInterval(-options.minimumAge)
    var hashes = ((try? index.hashesToShare()) ?? [])[...]
    var swaps: [Swap] = []
    var finished = false
    var tally = (files: 0, bytes: Int64(0))

    /// The swaps for a hash: only files still as they were when read; the keeper one already
    /// sharing, or else the first.
    func plan(_ hash: Data) throws -> [Swap] {
      var files: [SharedIndex.Row] = []
      for row in try index.files(withHash: hash) {
        if FileStamp.of(store.path + "/" + row.path) == row.stamp {
          files.append(row)
        } else {
          try index.forget(row.path)
        }
      }
      guard
        var keeper = files.first(where: { $0.sharing == .yes })
          ?? files.first(where: { $0.sharing == .no && $0.stamp.changedDate <= quietSince })
      else { return [] }
      let duplicates = files.filter {
        $0.path != keeper.path && $0.sharing == .no && $0.stamp.changedDate <= quietSince
      }
      guard !duplicates.isEmpty else { return [] }
      if keeper.sharing != .yes {
        keeper.sharing = .yes
        try index.put(keeper)
      }
      return duplicates.map { Swap(duplicate: $0, keeper: keeper) }
    }

    defer {
      report.filesShared += tally.files
      report.bytesSaved += tally.bytes
    }
    while !finished {
      if shouldYield() { return false }
      _ = try? exclusively {
        try index.batch {
          let start = Date()
          while Date().timeIntervalSince(start) < options.lockSlice {
            guard let swap = swaps.first else {
              guard let hash = hashes.popFirst() else {
                finished = true
                return
              }
              swaps = try plan(hash)
              continue
            }
            swaps.removeFirst()
            let path = store.path + "/" + swap.duplicate.path
            let keeperPath = store.path + "/" + swap.keeper.path
            willShare?(path)
            do {
              let stamp = try Cloning.share(
                path, with: keeperPath, duplicateStamp: swap.duplicate.stamp,
                keeperStamp: swap.keeper.stamp)
              var shared = swap.duplicate
              shared.stamp = stamp
              shared.sharing = .yes
              try index.put(shared)
              tally.files += 1
              tally.bytes += swap.duplicate.stamp.allocated
              progress.report(.sharing(files: tally.files, of: max(toShare, tally.files)))
            } catch SharingError.changed(let changed) {
              try index.forget(changed == keeperPath ? swap.keeper.path : swap.duplicate.path)
              // The keeper changed: the rest of its hash waits for the next sweep.
              if changed == keeperPath { swaps.removeAll { $0.keeper == swap.keeper } }
            } catch let error as SharingError where error.isLasting {
              // It can't be swapped (a permission, a locked folder): left alone until it
              // changes, rather than tried every time.
              var never = swap.duplicate
              never.sharing = .never
              try index.put(never)
            } catch {
              // It may work next time (the drive was full, say).
            }
          }
        }
      }
    }
    return true
  }

  /// Whether `folder` is a Cargo profile whose lock a build holds right now.
  private func isLockedCargoProfile(_ folder: String) -> Bool {
    let fd = open(folder + "/.cargo-lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return false }
    defer { close(fd) }
    if flock(fd, LOCK_SH | LOCK_NB) != 0 { return true }
    flock(fd, LOCK_UN)
    return false
  }
}

private struct Yielded: Error {}

/// For the copier: makes a file the drive already has a clone of that file, rather than writing
/// it again.
public protocol CloneSource: Sendable {
  /// Copies `source` to `destination` (which doesn't exist) by cloning a file already on the
  /// drive with the same contents, if there's one. Returns true if it did; otherwise the copier
  /// copies, then calls `copied` with the hash, if one was worked out.
  func clone(_ source: String, to destination: String) -> (cloned: Bool, hash: Data?)
  func copied(to destination: String, hash: Data)
}

struct StoreClones: CloneSource {
  let index: SharedIndex
  let store: String

  /// A path in the store, relative to it. The copier's paths may be standardized (`/var/…` for
  /// `/private/var/…`), so both spellings count.
  private func relative(_ path: String) -> String? {
    for base in [store, URL(fileURLWithPath: store).standardizedFileURL.path]
    where path.hasPrefix(base + "/") {
      return String(path.dropFirst(base.count + 1))
    }
    return nil
  }

  func clone(_ source: String, to destination: String) -> (cloned: Bool, hash: Data?) {
    var st = stat()
    guard relative(destination) != nil, lstat(source, &st) == 0, isShareable(st),
      Int64(st.st_size) >= SweepOptions().minimumSize,
      (try? index.hasHashed(size: Int64(st.st_size))) == true,
      let (hash, sourceStamp) = Cloning.hash(source)
    else { return (false, nil) }
    // The metadata to give the clone is the source's, as it was read.
    guard lstat(source, &st) == 0, FileStamp(st) == sourceStamp else { return (false, nil) }
    for keeper in (try? index.files(withHash: hash)) ?? [] where keeper.sharing != .never {
      let keeperPath = store + "/" + keeper.path
      guard FileStamp.of(keeperPath) == keeper.stamp else {
        try? index.forget(keeper.path)
        continue
      }
      do {
        try Cloning.cloneCopy(
          of: source, sourceStat: st, from: keeperPath, keeperStamp: keeper.stamp,
          to: destination)
      } catch {
        continue
      }
      if keeper.sharing != .yes {
        var marked = keeper
        marked.sharing = .yes
        try? index.put(marked)
      }
      if let rel = relative(destination), let stamp = FileStamp.of(destination) {
        try? index.put(SharedIndex.Row(path: rel, stamp: stamp, hash: hash, sharing: .yes))
      }
      return (true, hash)
    }
    return (false, hash)
  }

  func copied(to destination: String, hash: Data) {
    guard let rel = relative(destination), let stamp = FileStamp.of(destination) else { return }
    try? index.put(SharedIndex.Row(path: rel, stamp: stamp, hash: hash))
  }
}
