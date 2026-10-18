import Foundation
import XCTest

@testable import StowawayCore

/// Reconciling, recovery and drive changes: the paths that run without the user asking.
final class ReconcileTests: XCTestCase {
  /// A stowed .next folder with one file; returns the link and its copy on the drive.
  private func stowedNext(_ engine: Engine, _ s: Scratch) throws -> (local: URL, remote: URL) {
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/.next/old", "old")
    let local = s.root.appendingPathComponent("code/app/.next")
    try engine.adopt(local.path, kind: .next)
    let remote = try XCTUnwrap(engine.enterGrants()).appendingPathComponent(
      try XCTUnwrap(engine.entries().first).remote)
    return (local, remote)
  }

  /// A tool that deletes and recreates the folder (next build, cargo clean): its new folder takes
  /// the old copy's place, and what it deleted stays deleted.
  func testAToolsNewFolderReplacesTheOldCopy() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let (local, remote) = try stowedNext(engine, s)
    try FileManager.default.removeItem(at: local)
    try s.file("code/app/.next/new", "new")
    engine.reconcile()
    XCTAssertTrue(isSymlink(local.path))
    XCTAssertEqual(
      try String(contentsOf: local.appendingPathComponent("new"), encoding: .utf8), "new")
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: remote.appendingPathComponent("old").path))
  }

  /// A folder a tool is still writing isn't touched until it's been quiet.
  func testAFolderBeingWrittenIsLeftUntilItsQuiet() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let (local, _) = try stowedNext(engine, s)
    try FileManager.default.removeItem(at: local)
    try s.file("code/app/.next/new", "new")
    engine.quietPeriod = 60
    engine.reconcile()
    XCTAssertTrue(isRealDirectory(local.path), "still being written: left alone")
    engine.quietPeriod = -1
    engine.reconcile()
    XCTAssertTrue(isSymlink(local.path))
  }

  /// A link that leads somewhere else (the drive mounted under another name) is pointed back at
  /// the copy.
  func testALinkToTheWrongPlaceIsRepointed() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let (local, remote) = try stowedNext(engine, s)
    try FileManager.default.removeItem(at: local)
    try FileManager.default.createSymbolicLink(
      at: local, withDestinationURL: s.root.appendingPathComponent("Volumes/Drive 1/elsewhere"))
    engine.reconcile()
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: local.path), remote.path)
  }

  /// If the copy on the drive is gone, tools get a local folder rather than a dangling link.
  func testAMissingCopyFallsBackToALocalFolder() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let (local, remote) = try stowedNext(engine, s)
    try FileManager.default.removeItem(at: remote)
    engine.reconcile()
    XCTAssertTrue(isRealDirectory(local.path))
    XCTAssertEqual(engine.entries().first?.online, false)
  }

  /// A crash between moving the old copy aside and moving the new one in: recovery puts the new
  /// one in place.
  func testAnInterruptedReplacementIsRecovered() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let (local, remote) = try stowedNext(engine, s)
    let staging = remote.deletingLastPathComponent().appendingPathComponent(
      ".\(remote.lastPathComponent).stowaway-staging-abc")
    try FileManager.default.moveItem(at: remote, to: staging)
    engine.recover()
    XCTAssertTrue(isRealDirectory(remote.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: staging.path))
    XCTAssertEqual(
      try String(contentsOf: local.appendingPathComponent("old"), encoding: .utf8), "old")
  }

  /// An empty store left on another drive (after bringing everything back once) doesn't make it
  /// the drive that holds today's folders.
  func testALeftoverStoreDoesntMakeAnotherDriveAcceptable() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    _ = try stowedNext(engine, s)
    let other = try s.dir("other")
    try FileManager.default.createDirectory(
      at: other.appendingPathComponent(Engine.storeFolderName).appendingPathComponent(
        engine.installID),
      withIntermediateDirectories: true)
    XCTAssertThrowsError(try engine.grant(other, as: .drive))
  }

  /// Refusals (as opposed to failures that may pass) are marked, so automatic stowing can skip
  /// them until the folder changes.
  func testRefusalsAreMarked() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/node_modules/hand-cloned/.git/HEAD", "ref: refs/heads/main")
    XCTAssertThrowsError(try engine.adopt(code.appendingPathComponent("app/node_modules").path)) {
      XCTAssertEqual(($0 as? StowawayError)?.isRefusal, true)
    }
  }

  /// Deleting goes through the engine, with the same guard rails: a stowed folder is refused.
  func testDeletingAStowedFolderIsRefused() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    let (local, _) = try stowedNext(engine, s)
    let candidate = Candidate(kind: .next, path: local.path, project: s.path("code/app"))
    XCTAssertThrowsError(try engine.delete(candidate, roots: [code.path]))
    XCTAssertTrue(isSymlink(local.path))
  }

  /// Emptying a machine-wide cache keeps the folder, so the user's grant for it stays valid.
  func testDeletingACacheEmptiesIt() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    try s.file("caches/_npx/abc/package.json", "{}")
    let cache = s.root.appendingPathComponent("caches/_npx")
    let candidate = Candidate(kind: .npx, path: cache.path, project: nil)
    try engine.delete(candidate, roots: [cache.path])
    XCTAssertTrue(isRealDirectory(cache.path))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
  }
}
