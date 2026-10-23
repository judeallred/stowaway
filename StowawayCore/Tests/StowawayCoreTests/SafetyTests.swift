import Foundation
import XCTest

@testable import StowawayCore

/// Regression tests for the pre-submission security review: each reproduces a way data could be
/// lost or written outside Stowaway's folders, and checks it no longer happens.
final class SafetyTests: XCTestCase {
  private func cargo(_ s: Scratch) throws -> URL {
    try s.file("code/rs/Cargo.toml")
    try s.file("code/rs/target/CACHEDIR.TAG")
    try s.file("code/rs/target/debug/app", "binary")
    return s.root.appendingPathComponent("code/rs/target")
  }

  /// A package that gains a real file next to its links (a native build) and is then brought
  /// back keeps every file.
  func testPartiallyLinkedPackageSurvivesRelease() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    try s.file("code/app/package.json", #"{ "name": "app" }"#)
    try s.file("code/app/node_modules/a/package.json", #"{ "name": "a", "version": "1.0.0" }"#)
    try s.file("code/app/node_modules/a/index.js", "module.exports = 1")
    try s.file("code/app/node_modules/a/lib/x.js", "x-precious")
    let nm = s.root.appendingPathComponent("code/app/node_modules")
    try engine.adopt(nm.path)
    try s.file("code/app/node_modules/a/build/addon.node", "native")
    engine.reconcile()
    XCTAssertTrue(
      isSymlink(nm.appendingPathComponent("a/build").path), "the new folder was offloaded too")
    try engine.release(nm.path)
    for (rel, text) in [
      ("a/index.js", "module.exports = 1"), ("a/lib/x.js", "x-precious"),
      ("a/build/addon.node", "native"),
    ] {
      let path = nm.appendingPathComponent(rel).path
      XCTAssertFalse(isSymlink(path), rel)
      XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), text, rel)
    }
  }

  /// A copy set aside by an operation that never finished doesn't block the next one.
  func testALeftoverDoesntBlockReconnecting() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let target = try cargo(s)
    try engine.adopt(target.path, kind: .cargoTarget)
    let id = try XCTUnwrap(engine.entries().first).id
    try s.file("code/rs/.target.stowaway-old-\(id)/leftover", "x")
    try FileManager.default.removeItem(atPath: target.path)
    try s.file("code/rs/target/debug/offline", "new")
    engine.update(id) { $0.online = false }
    engine.reconcile()
    XCTAssertTrue(isSymlink(target.path))
    XCTAssertEqual(
      try String(contentsOf: target.appendingPathComponent("debug/offline"), encoding: .utf8), "new"
    )
    engine.recover()
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: s.path("code/rs/.target.stowaway-old-\(id)")), "swept")
  }

  /// Interrupted between setting the folder aside and linking it: recovery links it.
  func testRecoveryFinishesAnInterruptedOffload() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let target = try cargo(s)
    try engine.adopt(target.path, kind: .cargoTarget)
    try FileManager.default.removeItem(atPath: target.path)  // the link never got created
    try s.file("code/rs/.target.stowaway-old-deadbeef/debug/app", "binary")
    engine.recover()
    XCTAssertTrue(isSymlink(target.path))
    XCTAssertEqual(
      try String(contentsOf: target.appendingPathComponent("debug/app"), encoding: .utf8), "binary")
  }

  /// Merging a read-only cache (Go's module cache) onto the drive works.
  func testReadOnlyFoldersMerge() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/mod/github.com/x/y@v1/go.mod", "module y")
    let mod = code.appendingPathComponent("mod")
    chmod(s.path("code/mod/github.com/x/y@v1/go.mod"), 0o444)
    chmod(s.path("code/mod/github.com/x/y@v1"), 0o555)
    try engine.adopt(mod.path, kind: .go)
    let id = try XCTUnwrap(engine.entries().first).id
    try FileManager.default.removeItem(atPath: mod.path)
    try s.file("code/mod/github.com/x/y@v1/go.mod", "module y")
    try s.file("code/mod/github.com/x/z@v2/go.mod", "module z")
    chmod(s.path("code/mod/github.com/x/y@v1/go.mod"), 0o444)
    chmod(s.path("code/mod/github.com/x/y@v1"), 0o555)
    engine.update(id) { $0.online = false }
    engine.reconcile()
    XCTAssertTrue(isSymlink(mod.path))
    XCTAssertTrue(
      FileManager.default.fileExists(
        atPath: mod.appendingPathComponent("github.com/x/z@v2/go.mod").path))
  }

  /// A symlink planted in the drive copy never redirects a merge into the user's files.
  func testMergeDoesntWriteThroughALinkOnTheDrive() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let target = try cargo(s)
    try s.file("code/victim/src/main.rs", "precious source")
    try engine.adopt(target.path, kind: .cargoTarget)
    let entry = try XCTUnwrap(engine.entries().first)
    let remote = try XCTUnwrap(engine.enterGrants()).appendingPathComponent(entry.remote)
    try FileManager.default.createSymbolicLink(
      atPath: remote.appendingPathComponent("src").path,
      withDestinationPath: s.path("code/victim/src"))
    try FileManager.default.removeItem(atPath: target.path)
    try s.file("code/rs/target/src/main.rs", "build output")
    engine.update(entry.id) { $0.online = false }
    engine.reconcile()
    XCTAssertEqual(
      try String(contentsOfFile: s.path("code/victim/src/main.rs"), encoding: .utf8),
      "precious source")
    XCTAssertEqual(
      try String(contentsOf: target.appendingPathComponent("src/main.rs"), encoding: .utf8),
      "build output")
  }

  /// Bringing back a folder that's local while the drive is connected merges both sides.
  func testBringingBackAnOfflineEntryKeepsBothSides() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let target = try cargo(s)
    try engine.adopt(target.path, kind: .cargoTarget)
    let entry = try XCTUnwrap(engine.entries().first)
    try FileManager.default.removeItem(atPath: target.path)
    try s.file("code/rs/target/debug/offline", "new")
    engine.update(entry.id) { $0.online = false }
    try engine.release(target.path)
    XCTAssertTrue(isRealDirectory(target.path))
    XCTAssertEqual(
      try String(contentsOf: target.appendingPathComponent("debug/app"), encoding: .utf8), "binary")
    XCTAssertEqual(
      try String(contentsOf: target.appendingPathComponent("debug/offline"), encoding: .utf8), "new"
    )
    XCTAssertTrue(engine.entries().isEmpty)
  }

  /// With folders on an unplugged drive, a different location can't be chosen; the same one can.
  func testADifferentDriveIsRefusedWhileFoldersAreOnTheOldOne() throws {
    let s = try Scratch()
    let (engine, _, drive) = try makeEngine(s)
    let target = try cargo(s)
    try engine.adopt(target.path, kind: .cargoTarget)
    let other = try s.dir("other-drive")
    XCTAssertThrowsError(try engine.grant(other, as: .drive))
    XCTAssertNoThrow(try engine.grant(drive, as: .drive), "the same drive again is fine")
    XCTAssertEqual(engine.driveName, "drive")
  }

  func testTheContainerIsRecordedNotGuessed() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    try s.file("code/work/target/app/Cargo.toml")
    try s.file("code/work/target/app/target/CACHEDIR.TAG")
    try s.file("code/work/target/app/target/debug/deps/x.rlib", "x")
    let target = s.root.appendingPathComponent("code/work/target/app/target")
    try engine.adopt(
      target.appendingPathComponent("debug/deps").path, kind: .cargoTarget, container: target.path)
    XCTAssertEqual(engine.entries().first?.container, target.path)
  }

  func testFoldersHoldingARepositoryAreLeftAlone() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/node_modules/hand-cloned/.git/HEAD", "ref: refs/heads/main")
    try s.file("code/app/node_modules/hand-cloned/index.js", "uncommitted work")
    XCTAssertThrowsError(try engine.adopt(code.appendingPathComponent("app/node_modules").path))
    let candidate = Candidate(
      kind: .node, path: s.path("code/app/node_modules"), project: s.path("code/app"))
    XCTAssertNotNil(Cleaner().refusal(candidate, roots: [code.path], offloaded: []))
  }

  /// A store folder on the drive that's been swapped for a link isn't used: nothing is copied
  /// or deleted through it.
  func testAStoreThatIsALinkIsNotUsed() throws {
    let s = try Scratch()
    let (engine, code, drive) = try makeEngine(s)
    let elsewhere = try s.dir("elsewhere")
    try FileManager.default.createSymbolicLink(
      at: drive.appendingPathComponent(Engine.storeFolderName), withDestinationURL: elsewhere)
    XCTAssertNil(engine.enterGrants())
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/.next/page.js", "x")
    XCTAssertThrowsError(try engine.adopt(code.appendingPathComponent("app/.next").path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path), [])
  }

  func testSplitAndSparseIndexesFailClosed() throws {
    let s = try Scratch()
    try shell("/usr/bin/git", ["init", "-q"], in: s.root)
    try s.file("app/package.json", "{}")
    try s.file("app/node_modules/a/index.js", "x")
    try shell("/usr/bin/git", ["add", "app/package.json"], in: s.root)
    try shell("/usr/bin/git", ["update-index", "--split-index"], in: s.root)
    XCTAssertEqual(
      GitIndex.tracking(of: s.root.appendingPathComponent("app/node_modules")), .unknown)
  }

  func testReconnectingDoesntDoubleCountBytes() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let target = try cargo(s)
    try engine.adopt(target.path, kind: .cargoTarget)
    let entry = try XCTUnwrap(engine.entries().first)
    for _ in 0..<3 {
      try FileManager.default.removeItem(atPath: target.path)
      try s.file("code/rs/target/debug/app", "binary")
      engine.update(entry.id) { $0.online = false }
      engine.reconcile()
    }
    let bytes = try XCTUnwrap(engine.entries().first).bytes
    XCTAssertLessThan(bytes, 3 * 4096 + 1, "recounted, not added up: \(bytes)")
  }

  /// A repository nothing was added to has no index, and a worktree git has pruned points at
  /// an index that's gone: neither tracks anything, so their folders can be stowed.
  func testMissingIndexesTrackNothing() throws {
    let s = try Scratch()
    try s.file("fresh/.git/HEAD", "ref: refs/heads/main")
    try s.file("fresh/node_modules/a/index.js", "a")
    XCTAssertEqual(
      GitIndex.tracking(of: s.root.appendingPathComponent("fresh/node_modules")), .untracked)
    try s.file("pruned/.git", "gitdir: \(s.root.path)/main/.git/worktrees/gone")
    try s.file("pruned/node_modules/a/index.js", "a")
    XCTAssertEqual(
      GitIndex.tracking(of: s.root.appendingPathComponent("pruned/node_modules")), .untracked)
    // An index that's there but unreadable still fails closed.
    try s.file("broken/.git/index", "not an index")
    try s.file("broken/node_modules/a/index.js", "a")
    XCTAssertEqual(
      GitIndex.tracking(of: s.root.appendingPathComponent("broken/node_modules")), .unknown)
  }
}
