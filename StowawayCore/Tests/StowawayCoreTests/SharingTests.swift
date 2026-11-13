import Darwin
import Foundation
import Security
import XCTest

@testable import StowawayCore

// Sharing identical files on the drive (SharedFiles.swift, Sweep.swift). The scratch folders are
// on this Mac's APFS disk, which clones like an APFS drive does.

/// Random bytes: the files tests share must not share by accident.
func randomData(_ count: Int) -> Data {
  var bytes = [UInt8](repeating: 0, count: count)
  _ = SecRandomCopyBytes(kSecRandomDefault, count, &bytes)
  return Data(bytes)
}

func write(_ data: Data, to path: String) throws {
  try FileManager.default.createDirectory(
    atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
  try data.write(to: URL(fileURLWithPath: path))
}

func stamp(_ path: String) throws -> FileStamp { try XCTUnwrap(FileStamp.of(path)) }

/// A file's extended attributes, but for the one macOS manages itself (provenance).
func xattrs(_ path: String) -> [String] {
  let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
  guard size > 0 else { return [] }
  var names = [CChar](repeating: 0, count: size)
  listxattr(path, &names, size, XATTR_NOFOLLOW)
  return String(decoding: names.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    .split(separator: "\0").map(String.init).filter { $0 != "com.apple.provenance" }.sorted()
}

func setXattr(_ path: String, _ name: String, _ value: String) {
  _ = value.withCString { setxattr(path, name, $0, strlen($0), 0, XATTR_NOFOLLOW) }
}

func setModified(_ path: String, _ seconds: Int) {
  var times = [
    timespec(tv_sec: seconds, tv_nsec: 0), timespec(tv_sec: seconds, tv_nsec: 0),
  ]
  utimensat(AT_FDCWD, path, &times, AT_SYMLINK_NOFOLLOW)
}

func modified(_ path: String) -> Int {
  var st = stat()
  lstat(path, &st)
  return st.st_mtimespec.tv_sec
}

/// Sweeps that look at everything at once (no waiting for files to settle).
let eager: SweepOptions = {
  var options = SweepOptions()
  options.minimumSize = 1
  options.minimumAge = -1
  options.lowPriority = false
  // Tests change files between sweeps and expect each to see it.
  options.rewalkAfter = 0
  return options
}()

// MARK: - Swapping one file for a clone

final class CloningTests: XCTestCase {
  func testASwapKeepsTheDuplicatesOwnMetadataAndSharesTheStorage() throws {
    let s = try Scratch()
    let bytes = randomData(300_000)
    let keeper = s.path("k/lib.rlib")
    let duplicate = s.path("d/lib.rlib")
    try write(bytes, to: keeper)
    try write(bytes, to: duplicate)
    setXattr(keeper, "test.keeper-only", "k")
    setXattr(duplicate, "test.mine", "d")
    chmod(duplicate, 0o751)
    setModified(duplicate, 1_600_000_000)
    setModified(s.path("d"), 1_500_000_000)
    let before = try stamp(duplicate)

    let after = try Cloning.share(
      duplicate, with: keeper, duplicateStamp: before, keeperStamp: try stamp(keeper))

    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: duplicate)), bytes)
    XCTAssertNotEqual(after.inode, before.inode, "a new file, swapped in")
    XCTAssertEqual(after.allocated, before.allocated, "a clone still counts in full")
    XCTAssertEqual(modified(duplicate), 1_600_000_000, "its own dates, not the keeper's")
    var st = stat()
    lstat(duplicate, &st)
    XCTAssertEqual(st.st_mode & 0o7777, 0o751)
    XCTAssertEqual(xattrs(duplicate), ["test.mine"], "its own attributes, and only those")
    XCTAssertEqual(modified(s.path("d")), 1_500_000_000, "the folder's dates are kept")
    XCTAssertEqual(Cloning.privateSize(duplicate), 0, "shares all its storage")
    XCTAssertEqual(Cloning.privateSize(keeper), 0)

    // Copy-on-write: writing to one leaves the other as it was.
    let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: duplicate))
    try handle.seek(toOffset: 1000)
    try handle.write(contentsOf: Data(repeating: 7, count: 5000))
    try handle.close()
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: keeper)), bytes)
    XCTAssertGreaterThan(try XCTUnwrap(Cloning.privateSize(duplicate)), 0)
    XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: s.path("d")) == ["lib.rlib"])
  }

  /// The clone starts with the keeper's flags: the duplicate's own must be what it ends with,
  /// either way round.
  func testFlagsAreTheDuplicatesNotTheKeepers() throws {
    let s = try Scratch()
    let bytes = randomData(90_000)
    for (keeperFlags, duplicateFlags) in [(UF_HIDDEN, 0), (0, UF_HIDDEN)] {
      let keeper = s.path("k\(keeperFlags)")
      let duplicate = s.path("d\(keeperFlags)")
      try write(bytes, to: keeper)
      try write(bytes, to: duplicate)
      chflags(keeper, UInt32(keeperFlags))
      chflags(duplicate, UInt32(duplicateFlags))
      _ = try Cloning.share(
        duplicate, with: keeper, duplicateStamp: try stamp(duplicate),
        keeperStamp: try stamp(keeper))
      var st = stat()
      lstat(duplicate, &st)
      XCTAssertEqual(st.st_flags & UInt32(UF_HIDDEN), UInt32(duplicateFlags))
    }
  }

  /// Something else changing the folder during a swap: its change stands, and the folder's
  /// dates aren't put back over it.
  func testAnotherChangeToTheFolderDuringASwapStands() throws {
    let s = try Scratch()
    let bytes = randomData(90_000)
    try write(bytes, to: s.path("k"))
    try write(bytes, to: s.path("d/f"))
    setModified(s.path("d"), 1_500_000_000)
    let other = s.path("d/written-meanwhile")
    Cloning.afterCloning = { folder in
      if folder == s.path("d") { try? Data("x".utf8).write(to: URL(fileURLWithPath: other)) }
    }
    defer { Cloning.afterCloning = nil }
    _ = try Cloning.share(
      s.path("d/f"), with: s.path("k"), duplicateStamp: try stamp(s.path("d/f")),
      keeperStamp: try stamp(s.path("k")))
    XCTAssertGreaterThan(modified(s.path("d")), 1_500_000_000, "the other change's date stands")
    XCTAssertEqual(Cloning.privateSize(s.path("d/f")), 0, "and the swap still happened")
  }

  func testAChangedFileIsNeverSwapped() throws {
    let s = try Scratch()
    let bytes = randomData(100_000)
    let keeper = s.path("k")
    let duplicate = s.path("d")
    try write(bytes, to: keeper)
    try write(bytes, to: duplicate)
    let keeperStamp = try stamp(keeper)
    let duplicateStamp = try stamp(duplicate)

    // The duplicate rewritten (same size) since it was read.
    try write(randomData(100_000), to: duplicate)
    let rewritten = try Data(contentsOf: URL(fileURLWithPath: duplicate))
    XCTAssertThrowsError(
      try Cloning.share(
        duplicate, with: keeper, duplicateStamp: duplicateStamp, keeperStamp: keeperStamp))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: duplicate)), rewritten)

    // The keeper changed since: its contents may no longer be the duplicate's.
    let fresh = try stamp(duplicate)
    try write(randomData(100_000), to: keeper)
    XCTAssertThrowsError(
      try Cloning.share(duplicate, with: keeper, duplicateStamp: fresh, keeperStamp: keeperStamp))
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: duplicate)), rewritten)
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(atPath: s.root.path).sorted(), ["d", "k"],
      "no half-made clone left behind")
  }

  /// Go's module cache keeps read-only folders: opened up for the swap, then closed again.
  func testAReadOnlyFolderIsOpenedAndClosedAgain() throws {
    let s = try Scratch()
    let bytes = randomData(80_000)
    try write(bytes, to: s.path("k"))
    try write(bytes, to: s.path("ro/d"))
    chmod(s.path("ro/d"), 0o444)
    chmod(s.path("ro"), 0o555)
    defer { chmod(s.path("ro"), 0o755) }
    _ = try Cloning.share(
      s.path("ro/d"), with: s.path("k"), duplicateStamp: try stamp(s.path("ro/d")),
      keeperStamp: try stamp(s.path("k")))
    var st = stat()
    lstat(s.path("ro"), &st)
    XCTAssertEqual(st.st_mode & 0o777, 0o555)
    lstat(s.path("ro/d"), &st)
    XCTAssertEqual(st.st_mode & 0o777, 0o444)
    XCTAssertEqual(Cloning.privateSize(s.path("ro/d")), 0)
  }

  /// Hard links, locked and compressed files are left as they are.
  func testFilesThatCantBeSwappedSafelyAreLeftAlone() throws {
    let s = try Scratch()
    try write(randomData(70_000), to: s.path("plain"))
    var st = stat()
    lstat(s.path("plain"), &st)
    XCTAssertTrue(isShareable(st))

    link(s.path("plain"), s.path("hardlink"))
    lstat(s.path("plain"), &st)
    XCTAssertFalse(isShareable(st), "a hard link")

    try write(randomData(70_000), to: s.path("locked"))
    chflags(s.path("locked"), UInt32(UF_IMMUTABLE))
    defer { chflags(s.path("locked"), 0) }
    lstat(s.path("locked"), &st)
    XCTAssertFalse(isShareable(st), "immutable")

    try write(Data(repeating: 1, count: 200_000), to: s.path("plain-text"))
    try shell(
      "/usr/bin/ditto", ["--hfsCompression", s.path("plain-text"), s.path("compressed")],
      in: s.root)
    lstat(s.path("compressed"), &st)
    if st.st_flags & UInt32(UF_COMPRESSED) != 0 {
      XCTAssertFalse(isShareable(st), "compressed")
    }
  }

  func testHashingRefusesAFileThatIsntWhatWasExpected() throws {
    let s = try Scratch()
    try write(randomData(50_000), to: s.path("f"))
    let before = try stamp(s.path("f"))
    XCTAssertNotNil(Cloning.hash(s.path("f"), expected: before))
    try write(randomData(50_000), to: s.path("f"))
    XCTAssertNil(Cloning.hash(s.path("f"), expected: before))
    XCTAssertNil(Cloning.hash(s.path("missing")))
  }
}

// MARK: - Sweeping the drive

final class SweepTests: XCTestCase {
  /// Two Cargo projects whose builds compiled the same dependencies; returns their deps folders.
  /// Each has: `serde.rlib` (identical), `tokio.rlib` (identical), `app.rlib` (its own),
  /// `same-size.rlib` (same size, different bytes) and a small identical `tiny.d`.
  struct Twins {
    let a: URL
    let b: URL
    let serde: Data
    let tokio: Data
  }

  func twins(_ engine: Engine, _ s: Scratch, projects: [String] = ["a", "b"]) throws -> Twins {
    let serde = randomData(400_000)
    let tokio = randomData(250_000)
    for project in projects {
      try s.file("code/\(project)/Cargo.toml")
      try s.file("code/\(project)/target/CACHEDIR.TAG")
      let deps = "code/\(project)/target/debug/deps"
      try write(serde, to: s.path("\(deps)/libserde-1.rlib"))
      try write(tokio, to: s.path("\(deps)/libtokio-2.rlib"))
      try write(randomData(300_000), to: s.path("\(deps)/libapp-\(project).rlib"))
      try write(randomData(120_000), to: s.path("\(deps)/same-size.rlib"))
      try s.file("\(deps)/tiny.d", "deps")
      try engine.adopt(
        s.path(deps), kind: .cargoTarget, container: s.path("code/\(project)/target"))
    }
    return Twins(
      a: s.root.appendingPathComponent("code/a/target/debug/deps"),
      b: s.root.appendingPathComponent("code/b/target/debug/deps"), serde: serde, tokio: tokio)
  }

  /// A file's path on the drive, through its stowed folder's link.
  func onDrive(_ url: URL, _ name: String) -> String {
    canonicalPath(url.appendingPathComponent(name).path)
  }

  func testASweepSharesIdenticalFilesAndCountsWhatItSaved() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    let stowedBefore = engine.offloadedBytes

    let report = engine.sweepSharedFiles(eager)

    XCTAssertEqual(report.outcome, .finished)
    XCTAssertEqual(report.filesShared, 3, "serde, tokio and tiny.d; never same-size")
    let saved =
      try stamp(onDrive(t.b, "libserde-1.rlib")).allocated
      + stamp(onDrive(t.b, "libtokio-2.rlib")).allocated + stamp(onDrive(t.b, "tiny.d")).allocated
    XCTAssertEqual(report.bytesSaved, saved)
    XCTAssertEqual(engine.savedBySharing(), saved)
    for deps in [t.a, t.b] {
      XCTAssertEqual(Cloning.privateSize(onDrive(deps, "libserde-1.rlib")), 0)
      XCTAssertEqual(Cloning.privateSize(onDrive(deps, "libtokio-2.rlib")), 0)
      XCTAssertGreaterThan(try XCTUnwrap(Cloning.privateSize(onDrive(deps, "same-size.rlib"))), 0)
    }
    // Read through the Mac's links, everything is as it was.
    XCTAssertEqual(try Data(contentsOf: t.b.appendingPathComponent("libserde-1.rlib")), t.serde)
    XCTAssertEqual(try Data(contentsOf: t.a.appendingPathComponent("libtokio-2.rlib")), t.tokio)
    // Sizes (and the free limit) still count everything in full.
    engine.recountStowed()
    XCTAssertEqual(engine.offloadedBytes, stowedBefore)
  }

  func testASecondSweepReadsNothingAgain() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try twins(engine, s)
    _ = engine.sweepSharedFiles(eager)
    let saved = engine.savedBySharing()

    let again = engine.sweepSharedFiles(eager)
    XCTAssertEqual(again.outcome, .finished)
    XCTAssertEqual(again.filesHashed, 0)
    XCTAssertEqual(again.filesShared, 0)
    XCTAssertEqual(engine.savedBySharing(), saved)
  }

  /// The index outlives the app: a relaunch doesn't read everything again.
  func testTheIndexOutlivesTheEngine() throws {
    let s = try Scratch()
    let suite = "stowaway-tests-\(UUID().uuidString)"
    let state = try s.dir("state")
    let first = Engine(
      defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), stateDirectory: state)
    first.quietPeriod = -1
    try first.grant(try s.dir("code"), as: .root)
    try first.grant(try s.dir("drive"), as: .drive)
    _ = try twins(first, s)
    _ = first.sweepSharedFiles(eager)

    let second = Engine(
      defaults: try XCTUnwrap(UserDefaults(suiteName: suite)), stateDirectory: state)
    second.quietPeriod = -1
    let report = second.sweepSharedFiles(eager)
    XCTAssertEqual(report.filesHashed, 0)
    XCTAssertEqual(second.savedBySharing(), first.savedBySharing())
  }

  /// A third project stowed later clones what the drive has rather than writing it again,
  /// keeping its own files' dates.
  func testAFileTheDriveHasIsClonedWhenStowed() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    _ = engine.sweepSharedFiles(eager)
    let saved = engine.savedBySharing()

    try s.file("code/c/Cargo.toml")
    try s.file("code/c/target/CACHEDIR.TAG")
    let deps = s.path("code/c/target/debug/deps")
    try write(t.serde, to: deps + "/libserde-1.rlib")
    setModified(deps + "/libserde-1.rlib", 1_650_000_000)
    try write(randomData(90_000), to: deps + "/libc-only.rlib")
    let stats = try engine.adopt(deps, kind: .cargoTarget, container: s.path("code/c/target"))

    XCTAssertEqual(stats.cloned, 1)
    let c = URL(fileURLWithPath: deps)
    XCTAssertEqual(Cloning.privateSize(onDrive(c, "libserde-1.rlib")), 0)
    XCTAssertEqual(try Data(contentsOf: c.appendingPathComponent("libserde-1.rlib")), t.serde)
    XCTAssertEqual(modified(onDrive(c, "libserde-1.rlib")), 1_650_000_000, "its own date")
    XCTAssertEqual(
      engine.savedBySharing(), saved + (try stamp(onDrive(c, "libserde-1.rlib"))).allocated)
    // Nothing left for the next sweep to do there.
    XCTAssertEqual(engine.sweepSharedFiles(eager).filesShared, 0)
  }

  /// A file the drive has, changed on the drive since: it's copied, not cloned from the changed
  /// one.
  func testAChangedTwinIsCopiedNotCloned() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    _ = engine.sweepSharedFiles(eager)
    // Both copies on the drive rewritten (same size, other bytes) behind the index's back.
    for deps in [t.a, t.b] { try write(randomData(400_000), to: onDrive(deps, "libserde-1.rlib")) }

    try s.file("code/c/Cargo.toml")
    try s.file("code/c/target/CACHEDIR.TAG")
    let deps = s.path("code/c/target/debug/deps")
    try write(t.serde, to: deps + "/libserde-1.rlib")
    let stats = try engine.adopt(deps, kind: .cargoTarget, container: s.path("code/c/target"))
    XCTAssertEqual(stats.cloned, 0)
    XCTAssertEqual(
      try Data(contentsOf: URL(fileURLWithPath: deps + "/libserde-1.rlib")), t.serde)
  }

  /// Writing to a shared file (a rebuild through the link) leaves its twin alone, and the
  /// savings shrink once the sweep sees it.
  func testWritingToASharedFileLeavesItsTwinAlone() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    _ = engine.sweepSharedFiles(eager)
    let saved = engine.savedBySharing()
    let serdeSize = try stamp(onDrive(t.b, "libserde-1.rlib")).allocated

    let handle = try FileHandle(forWritingTo: t.b.appendingPathComponent("libserde-1.rlib"))
    try handle.write(contentsOf: Data("rebuilt".utf8))
    try handle.close()
    XCTAssertEqual(try Data(contentsOf: t.a.appendingPathComponent("libserde-1.rlib")), t.serde)

    let report = engine.sweepSharedFiles(eager)
    XCTAssertEqual(report.filesShared, 0, "different now: nothing to share")
    XCTAssertEqual(engine.savedBySharing(), saved - serdeSize)
  }

  func testFilesChangedRecentlyWait() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try twins(engine, s)
    var patient = eager
    patient.minimumAge = 3600
    let report = engine.sweepSharedFiles(patient)
    XCTAssertEqual(report.outcome, .finished)
    XCTAssertEqual(report.filesHashed, 0)
    XCTAssertEqual(report.filesShared, 0)
  }

  /// Smaller files than the minimum aren't worth it and aren't looked at.
  func testSmallFilesAreLeftOut() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try twins(engine, s)
    var options = eager
    options.minimumSize = 200_000
    let report = engine.sweepSharedFiles(options)
    XCTAssertEqual(report.filesShared, 2, "serde and tokio; tiny.d and same-size are too small")
  }

  /// A Cargo build holding its profile's lock on the Mac: that folder waits.
  func testAFolderABuildHoldsIsLeftAlone() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    let lock = try s.file("code/b/target/debug/.cargo-lock")
    let fd = open(lock.path, O_RDONLY)
    defer { close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)

    let report = engine.sweepSharedFiles(eager)
    XCTAssertEqual(report.filesShared, 0, "b is being built; a has nothing to share alone")
    XCTAssertGreaterThan(try XCTUnwrap(Cloning.privateSize(onDrive(t.b, "libserde-1.rlib"))), 0)

    flock(fd, LOCK_UN)
    XCTAssertEqual(engine.sweepSharedFiles(eager).filesShared, 3)
  }

  /// The shared Cargo build folder is on the drive, its locks too: a locked profile is skipped.
  func testALockedProfileInTheSharedBuildFolderIsSkipped() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let bytes = randomData(200_000)
    try s.dir("code/.cargo")
    let folder = "code/.cargo/stowaway-build"
    for project in ["11/aaaa", "22/bbbb"] {
      try write(bytes, to: s.path("\(folder)/\(project)/debug/deps/libx.rlib"))
      try s.file("\(folder)/\(project)/debug/.cargo-lock")
    }
    try engine.adopt(s.path(folder), kind: .cargoBuild)
    let lock = canonicalPath(s.path("\(folder)/22/bbbb/debug/.cargo-lock"))
    let fd = open(lock, O_RDONLY)
    defer { close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)

    XCTAssertEqual(engine.sweepSharedFiles(eager).filesShared, 0)
    flock(fd, LOCK_UN)
    XCTAssertEqual(engine.sweepSharedFiles(eager).filesShared, 1)
  }

  /// Asked to make way, a sweep stops between files; the next one finishes the job.
  func testYieldingStopsAndTheNextSweepFinishes() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try twins(engine, s, projects: ["a", "b", "c", "d"])
    let asked = Counter()
    let report = engine.sweepSharedFiles(eager) { asked.next() > 3 }
    XCTAssertEqual(report.outcome, .yielded)

    let rest = engine.sweepSharedFiles(eager)
    XCTAssertEqual(rest.outcome, .finished)
    XCTAssertEqual(report.filesShared + rest.filesShared, 9, "3 files in each of b, c and d")
  }

  /// A file that changes at the last moment is left as it is now, never swapped.
  func testAFileChangedJustBeforeItsSwapIsLeftAsItIs() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    let latest = randomData(400_000)
    let changed = Box()
    // Whichever copy is the one being swapped, it's rewritten just before.
    engine.willShare = { path in
      if path.hasSuffix("libserde-1.rlib") {
        changed.path = path
        try? latest.write(to: URL(fileURLWithPath: path))
      }
    }
    let report = engine.sweepSharedFiles(eager)
    let path = try XCTUnwrap(changed.path)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), latest)
    XCTAssertEqual(report.filesShared, 2, "tokio and tiny.d only")
    _ = t
  }

  func testAHalfMadeCloneFromACrashIsRemoved() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    let leftover = onDrive(t.a, "") + "/" + Cloning.temporaryPrefix + "1234abcd"
    try write(randomData(10), to: leftover)
    _ = engine.sweepSharedFiles(eager)
    XCTAssertFalse(FileManager.default.fileExists(atPath: leftover))
  }

  /// Deleted on the drive, brought back, deleted by Stowaway: what was saved goes with them.
  func testSavingsFollowFilesThatGo() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s, projects: ["a", "b", "c"])
    _ = engine.sweepSharedFiles(eager)
    let each = try stamp(onDrive(t.a, "libserde-1.rlib")).allocated
    let saved = engine.savedBySharing()

    // A tool deleting one on the drive: noticed by the next sweep.
    try FileManager.default.removeItem(at: t.b.appendingPathComponent("libserde-1.rlib"))
    _ = engine.sweepSharedFiles(eager)
    XCTAssertEqual(engine.savedBySharing(), saved - each)

    // Deleting a stowed folder forgets its files at once; the rest still share.
    try engine.discard(t.b.path)
    let c = URL(fileURLWithPath: s.path("code/c/target/debug/deps"))
    try engine.release(c.path)
    let left = engine.savedBySharing()
    XCTAssertEqual(left, 0, "a alone shares with nothing now")
    XCTAssertEqual(try Data(contentsOf: c.appendingPathComponent("libserde-1.rlib")), t.serde)
    XCTAssertEqual(try Data(contentsOf: t.a.appendingPathComponent("libserde-1.rlib")), t.serde)
  }

  /// The copy every other one was cloned from going away doesn't stop the rest sharing, or a
  /// later one joining them.
  func testTheRestStillShareWhenTheFirstGoes() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s, projects: ["a", "b", "c"])
    _ = engine.sweepSharedFiles(eager)
    let each = try stamp(onDrive(t.a, "libserde-1.rlib")).allocated
    try engine.discard(t.a.path)
    _ = engine.sweepSharedFiles(eager)
    let b = engine.savedBySharing()
    XCTAssertEqual(
      b,
      each + (try stamp(onDrive(t.b, "libtokio-2.rlib"))).allocated
        + (try stamp(onDrive(t.b, "tiny.d"))).allocated)

    try s.file("code/d/Cargo.toml")
    try s.file("code/d/target/CACHEDIR.TAG")
    let deps = s.path("code/d/target/debug/deps")
    try write(t.serde, to: deps + "/libserde-1.rlib")
    let stats = try engine.adopt(deps, kind: .cargoTarget, container: s.path("code/d/target"))
    XCTAssertEqual(stats.cloned, 1)
    XCTAssertEqual(engine.savedBySharing(), b + each)
  }

  /// npm packages on the drive share too, and their folders keep the dates npm checks.
  func testIdenticalPackagesShareAndKeepTheirDates() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let bundle = randomData(150_000)
    for app in ["x", "y"] {
      try s.file("code/\(app)/package.json", #"{ "name": "\#(app)" }"#)
      try s.file("code/\(app)/node_modules/big/package.json", #"{ "name": "big" }"#)
      try write(bundle, to: s.path("code/\(app)/node_modules/big/dist/big.js"))
      try engine.adopt(s.path("code/\(app)/node_modules"))
    }
    let files = ["x", "y"].map { s.path("code/\($0)/node_modules/big/dist/big.js") }
    let folders = files.map { (canonicalPath($0) as NSString).deletingLastPathComponent }
    XCTAssertNotEqual(folders[0], folders[1], "each project's copy is on the drive")
    let dates = folders.map(modified)

    XCTAssertGreaterThanOrEqual(engine.sweepSharedFiles(eager).filesShared, 1)
    for file in files {
      XCTAssertEqual(Cloning.privateSize(canonicalPath(file)), 0)
      XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: file)), bundle)
    }
    XCTAssertEqual(folders.map(modified), dates)
  }

  /// A file that can't be swapped (its folder locked) is left alone, and not tried every sweep.
  func testAFileThatCantBeSwappedIsntRetriedUntilItChanges() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    // Both folders, so whichever copy is swapped can't be.
    let folders = [onDrive(t.a, ""), onDrive(t.b, "")]
    for folder in folders { chflags(folder, UInt32(UF_IMMUTABLE)) }
    defer { for folder in folders { chflags(folder, 0) } }
    let first = engine.sweepSharedFiles(eager)
    XCTAssertEqual(first.filesShared, 0)
    let second = engine.sweepSharedFiles(eager)
    XCTAssertEqual(second.filesShared, 0)
    XCTAssertEqual(second.filesHashed, 0)
  }

  func testNothingHappensWhilePaused() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try twins(engine, s)
    engine.paused = true
    XCTAssertEqual(engine.sweepSharedFiles(eager).outcome, .unavailable)
  }

  func testOnlyOneSweepAtATime() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try twins(engine, s)
    engine.sweepLock.lock()
    defer { engine.sweepLock.unlock() }
    XCTAssertEqual(engine.sweepSharedFiles(eager).outcome, .busy)
  }

  /// Another drive (or the same one, reformatted) starts with an empty index, and one that
  /// can't be read is started again rather than trusted.
  func testAnotherDriveOrADamagedIndexStartsAfresh() throws {
    let s = try Scratch()
    let url = s.root.appendingPathComponent("index.sqlite")
    let row = SharedIndex.Row(
      path: "x/y", stamp: FileStamp(inode: 1, size: 2, allocated: 4096, modified: 3, changed: 4),
      hash: Data([1, 2]), sharing: .yes)
    try SharedIndex(at: url, identity: "drive-1").put(row)
    XCTAssertEqual(try SharedIndex(at: url, identity: "drive-1").row("x/y"), row)
    XCTAssertEqual(try SharedIndex(at: url, identity: "drive-2").count(), 0)

    try Data("not a database".utf8).write(to: url)
    XCTAssertEqual(try SharedIndex(at: url, identity: "drive-2").count(), 0)
  }

  /// The index's sums: per hash, every sharing copy but one; never-shared and unshared copies
  /// don't count.
  func testSavingsCountEverySharingCopyButOne() throws {
    let s = try Scratch()
    let index = try SharedIndex(at: s.root.appendingPathComponent("i.sqlite"), identity: "d")
    func put(_ path: String, _ hash: UInt8, _ sharing: SharedIndex.Sharing, _ allocated: Int64)
      throws
    {
      try index.put(
        SharedIndex.Row(
          path: path,
          stamp: FileStamp(
            inode: 0, size: allocated, allocated: allocated, modified: 0, changed: 0),
          hash: Data([hash]), sharing: sharing))
    }
    try put("a1", 1, .yes, 100)
    try put("a2", 1, .yes, 100)
    try put("a3", 1, .yes, 100)
    try put("a4", 1, .no, 100)
    try put("b1", 2, .yes, 50)
    try put("b2", 2, .never, 50)
    XCTAssertEqual(try index.savedBytes(), 200)
    XCTAssertEqual(try index.hashesToShare(), [Data([1])], "b2 can't share; a4 can")
    try index.forget("a")
    XCTAssertEqual(try index.savedBytes(), 200, "a prefix of a name isn't its folder")
    try index.put(
      SharedIndex.Row(
        path: "dir/f", stamp: FileStamp(inode: 0, size: 1, allocated: 1, modified: 0, changed: 0)))
    try index.move("dir", to: "renamed")
    XCTAssertNotNil(try index.row("renamed/f"))
    try index.forget("renamed")
    XCTAssertNil(try index.row("renamed/f"))
  }

  /// A drive that can't clone (ExFAT, HFS+): nothing is shared, and stowing copies as always.
  func testADriveThatCantCloneIsLeftAsItIs() throws {
    let s = try Scratch()
    // HFS+ can't clone either. (An ExFAT image can't be formatted from a test process.)
    let image = s.root.appendingPathComponent("hfs.dmg").path
    try shell(
      "/usr/bin/hdiutil",
      ["create", "-quiet", "-fs", "HFS+", "-size", "40m", "-volname", "StowawayHFS", image],
      in: s.root)
    let mount = try s.dir("hfs")
    try shell(
      "/usr/bin/hdiutil", ["attach", "-quiet", "-nobrowse", "-mountpoint", mount.path, image],
      in: s.root)
    defer { _ = try? shell("/usr/bin/hdiutil", ["detach", "-force", mount.path], in: s.root) }
    XCTAssertFalse(Cloning.volumeSupportsCloning(mount))

    let engine = Engine(
      defaults: try XCTUnwrap(UserDefaults(suiteName: "stowaway-tests-\(UUID().uuidString)")),
      stateDirectory: try s.dir("state"))
    engine.quietPeriod = -1
    try engine.grant(try s.dir("code"), as: .root)
    try engine.grant(mount, as: .drive)
    let t = try twins(engine, s)
    XCTAssertEqual(engine.sweepSharedFiles(eager).outcome, .unsupported)
    XCTAssertEqual(engine.savedBySharing(), 0)
    XCTAssertEqual(try Data(contentsOf: t.b.appendingPathComponent("libserde-1.rlib")), t.serde)
  }
  /// A tool replacing a stowed folder (cargo clean, then a build): the new folder goes onto the
  /// drive cloning what it can, and the old copy's files drop out of the savings.
  func testAReplacedFolderClonesAndKeepsTheSavingsRight() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    _ = engine.sweepSharedFiles(eager)
    let saved = engine.savedBySharing()

    // b rebuilt from scratch: the link replaced by a real folder with the same outputs.
    let fm = FileManager.default
    try fm.removeItem(at: t.b)
    try write(t.serde, to: t.b.appendingPathComponent("libserde-1.rlib").path)
    try write(t.tokio, to: t.b.appendingPathComponent("libtokio-2.rlib").path)
    engine.reconcile()

    XCTAssertTrue(isSymlink(t.b.path))
    XCTAssertEqual(Cloning.privateSize(onDrive(t.b, "libserde-1.rlib")), 0, "cloned on the way")
    XCTAssertEqual(try Data(contentsOf: t.b.appendingPathComponent("libtokio-2.rlib")), t.tokio)
    let tiny = try stamp(onDrive(t.a, "tiny.d")).allocated
    XCTAssertEqual(engine.savedBySharing(), saved - tiny, "tiny.d wasn't rebuilt")
    // And a sweep agrees.
    _ = engine.sweepSharedFiles(eager)
    XCTAssertEqual(engine.savedBySharing(), saved - tiny)
  }

  /// The copy being cloned from disappearing mid-sweep: nothing is lost, nothing left behind.
  func testATwinVanishingMidSweepLosesNothing() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    let a = onDrive(t.a, "libserde-1.rlib")
    let b = onDrive(t.b, "libserde-1.rlib")
    engine.willShare = { path in
      // Whichever is the keeper goes.
      if path == a { unlink(b) }
      if path == b { unlink(a) }
    }
    _ = engine.sweepSharedFiles(eager)
    let survivor = FileManager.default.fileExists(atPath: a) ? a : b
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: survivor)), t.serde)
    for folder in [onDrive(t.a, ""), onDrive(t.b, "")] {
      XCTAssertFalse(
        try FileManager.default.contentsOfDirectory(atPath: folder).contains {
          $0.hasPrefix(Cloning.temporaryPrefix)
        })
    }
  }

  /// Stowing and bringing back while a sweep runs: they take turns with the engine's lock, and
  /// every file stays what it was.
  func testStowingWhileASweepRunsLosesNothing() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let projects = (0..<6).map { "p\($0)" }
    let t = try twins(engine, s, projects: Array(projects.prefix(3)))
    for project in projects.dropFirst(3) {
      try s.file("code/\(project)/Cargo.toml")
      try s.file("code/\(project)/target/CACHEDIR.TAG")
      try write(t.serde, to: s.path("code/\(project)/target/debug/deps/libserde-1.rlib"))
      try write(t.tokio, to: s.path("code/\(project)/target/debug/deps/libtokio-2.rlib"))
    }
    let slow = {
      var options = eager
      options.lockSlice = 0.001
      return options
    }()
    let group = DispatchGroup()
    for _ in 0..<3 {
      DispatchQueue.global().async(group: group) { _ = engine.sweepSharedFiles(slow) }
    }
    for project in projects.dropFirst(3) {
      try engine.adopt(
        s.path("code/\(project)/target/debug/deps"), kind: .cargoTarget,
        container: s.path("code/\(project)/target"))
    }
    try engine.release(s.path("code/p0/target/debug/deps"))
    group.wait()
    _ = engine.sweepSharedFiles(eager)

    for project in projects {
      let deps = URL(fileURLWithPath: s.path("code/\(project)/target/debug/deps"))
      XCTAssertEqual(try Data(contentsOf: deps.appendingPathComponent("libserde-1.rlib")), t.serde)
      XCTAssertEqual(try Data(contentsOf: deps.appendingPathComponent("libtokio-2.rlib")), t.tokio)
    }
    // p1…p5 on the drive: 5 copies each of serde and tokio, all sharing.
    let each =
      try stamp(
        onDrive(URL(fileURLWithPath: s.path("code/p1/target/debug/deps")), "libserde-1.rlib")
      )
      .allocated
      + stamp(onDrive(URL(fileURLWithPath: s.path("code/p1/target/debug/deps")), "libtokio-2.rlib"))
      .allocated
    let tiny = try stamp(
      onDrive(URL(fileURLWithPath: s.path("code/p1/target/debug/deps")), "tiny.d")
    )
    .allocated
    XCTAssertEqual(engine.savedBySharing(), 4 * each + tiny, "p1 and p2 share tiny.d too")
  }

  /// Folders stowed and then deleted while the app wasn't watching drop out of the index.
  func testFoldersNoLongerStowedDropOut() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    _ = engine.sweepSharedFiles(eager)
    // Forgotten behind the sweep's back (a list edited, say): its files are no one's now.
    try engine.save(
      engine.entries().filter { !t.b.path.hasPrefix($0.local) && $0.local != t.b.path })
    _ = engine.sweepSharedFiles(eager)
    XCTAssertEqual(engine.savedBySharing(), 0)
  }

  /// Dropping the drive: what sharing saved there isn't shown any more.
  func testForgettingTheDriveForgetsItsSavings() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try twins(engine, s)
    _ = engine.sweepSharedFiles(eager)
    XCTAssertGreaterThan(engine.savedBySharing(), 0)
    try engine.abandonDrive()
    XCTAssertEqual(engine.savedBySharing(), 0)
  }

  /// Unread files come a page at a time, biggest first, each once.
  func testUnreadFilesComeInPages() throws {
    let s = try Scratch()
    let index = try SharedIndex(at: s.root.appendingPathComponent("i.sqlite"), identity: "d")
    for (path, size) in [("a", 10), ("b", 10), ("c", 30), ("d", 30), ("e", 30), ("lonely", 99)] {
      try index.put(
        SharedIndex.Row(
          path: path,
          stamp: FileStamp(
            inode: 0, size: Int64(size), allocated: Int64(size), modified: 0, changed: 0)))
    }
    var seen: [String] = []
    var page = try index.unhashedWithTwins(limit: 2)
    while !page.isEmpty {
      seen += page.map(\.path)
      page = try index.unhashedWithTwins(after: page.last, limit: 2)
    }
    XCTAssertEqual(seen, ["c", "d", "e", "a", "b"], "no twin for lonely")
  }

  /// A sweep picking up after making way doesn't walk the drive again if it walked it just now;
  /// a later one does.
  func testAResumedSweepSkipsARecentWalk() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try twins(engine, s)
    _ = engine.sweepSharedFiles(eager)
    _ = try twins(engine, s, projects: ["c"])
    var resumed = eager
    resumed.rewalkAfter = 3600
    let soon = engine.sweepSharedFiles(resumed)
    XCTAssertEqual(soon.filesSeen, 0)
    XCTAssertEqual(soon.filesShared, 0)
    // (c's dependencies are its own random bytes; only tiny.d matches a's and b's.)
    XCTAssertEqual(engine.sweepSharedFiles(eager).filesShared, 1, "c's tiny.d, once walked")
  }

  /// The shared Cargo build folder is always being written by some build: it's swept anyway,
  /// minding only its profiles' locks.
  func testTheSharedBuildFolderIsSweptWhileOthersBuild() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let bytes = randomData(200_000)
    try s.dir("code/.cargo")
    let folder = "code/.cargo/stowaway-build"
    for project in ["11/aaaa", "22/bbbb"] {
      try write(bytes, to: s.path("\(folder)/\(project)/debug/deps/libx.rlib"))
    }
    try engine.adopt(s.path(folder), kind: .cargoBuild)
    // Something changed there a moment ago: any other stowed folder would wait.
    engine.quietPeriod = 3600
    XCTAssertEqual(engine.sweepSharedFiles(eager).filesShared, 1)
  }

  /// Progress is reported for each step, with totals.
  func testProgressIsReported() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try twins(engine, s)
    let seen = Recorder()
    _ = engine.sweepSharedFiles(eager, progress: { seen.add($0) })
    let steps = seen.all
    XCTAssertEqual(steps.first, .walking(files: 0))
    XCTAssertTrue(steps.contains { if case .reading(0, let of) = $0 { of > 0 } else { false } })
    XCTAssertTrue(steps.contains(.sharing(files: 0, of: 3)))
  }

  /// The walk forgets files that went, and files no longer worth sharing, without holding a
  /// folder's whole list in memory (checked a page at a time).
  func testTheWalkForgetsWhatsGoneOrNoLongerEligible() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let t = try twins(engine, s)
    _ = engine.sweepSharedFiles(eager)
    let saved = engine.savedBySharing()
    let serde = try stamp(onDrive(t.b, "libserde-1.rlib")).allocated
    let tokio = try stamp(onDrive(t.b, "libtokio-2.rlib")).allocated
    // One gone, one hard-linked (no longer safe to swap).
    unlink(onDrive(t.b, "libserde-1.rlib"))
    link(onDrive(t.b, "libtokio-2.rlib"), onDrive(t.b, "tokio-link"))
    _ = engine.sweepSharedFiles(eager)
    XCTAssertEqual(engine.savedBySharing(), saved - serde - tokio)
  }

  func testOnlyLastingFailuresStopRetries() {
    XCTAssertTrue(SharingError.failed("x", "y", EPERM).isLasting)
    XCTAssertTrue(SharingError.failed("x", "y", EACCES).isLasting)
    XCTAssertFalse(SharingError.failed("x", "y", ENOSPC).isLasting, "a full drive may clear")
    XCTAssertFalse(SharingError.failed("x", "y", EIO).isLasting)
    XCTAssertFalse(SharingError.changed("x").isLasting)
  }
}

/// Progress reports, from any thread.
final class Recorder: @unchecked Sendable {
  private let lock = NSLock()
  private var items: [SweepProgress] = []
  var all: [SweepProgress] { lock.withLock { items } }
  func add(_ item: SweepProgress) { lock.withLock { items.append(item) } }
}

/// A value set from another thread.
final class Box: @unchecked Sendable {
  var path: String?
}

/// Counts calls from any thread.
final class Counter: @unchecked Sendable {
  private let lock = NSLock()
  private var n = 0
  func next() -> Int {
    lock.withLock {
      n += 1
      return n
    }
  }
}
