import Foundation
import XCTest

@testable import StowawayCore

final class EngineTests: XCTestCase {
  /// A real volume as the drive, so unplugging is a forced detach, as when a cable is pulled.
  /// (Bookmarks follow a renamed folder, so renaming one doesn't look like an unplug.)
  func testFolderOffloadSurvivesTheDriveComingAndGoing() throws {
    let s = try Scratch()
    let image = s.root.appendingPathComponent("drive.sparsebundle").path
    try shell(
      "/usr/bin/hdiutil",
      [
        "create", "-quiet", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-size", "200m", "-volname",
        "StowawayTest", image,
      ],
      in: s.root)
    let drive = try s.dir("mnt")
    let attach = ["attach", "-quiet", "-nobrowse", "-mountpoint", drive.path, image]
    try shell("/usr/bin/hdiutil", attach, in: s.root)
    defer { _ = try? shell("/usr/bin/hdiutil", ["detach", "-force", drive.path], in: s.root) }
    let engine = Engine(
      defaults: try XCTUnwrap(UserDefaults(suiteName: "stowaway-tests-\(UUID().uuidString)")),
      stateDirectory: try s.dir("state"))
    engine.quietPeriod = -1
    let code = try s.dir("code")
    try engine.grant(code, as: .root)
    try engine.grant(drive, as: .drive)
    try s.file("code/rs/Cargo.toml")
    try s.file("code/rs/target/CACHEDIR.TAG")
    try s.file("code/rs/target/debug/app", "binary")
    let target = code.appendingPathComponent("rs/target")

    try engine.adopt(target.path, kind: .cargoTarget)
    XCTAssertTrue(isSymlink(target.path))
    XCTAssertEqual(
      try String(contentsOf: target.appendingPathComponent("debug/app"), encoding: .utf8), "binary")
    XCTAssertEqual(engine.entries().count, 1)

    // Unplug: the volume vanishes, the link becomes an empty local folder.
    try shell("/usr/bin/hdiutil", ["detach", "-force", drive.path], in: s.root)
    engine.reconcile()
    XCTAssertTrue(isRealDirectory(target.path))
    try s.file("code/rs/target/debug/built-offline", "new")

    // Replug: the offline build is merged onto the drive and the link returns.
    try shell("/usr/bin/hdiutil", attach, in: s.root)
    engine.reconcile()
    XCTAssertTrue(isSymlink(target.path))
    XCTAssertEqual(
      try String(contentsOf: target.appendingPathComponent("debug/built-offline"), encoding: .utf8),
      "new")
    XCTAssertEqual(
      try String(contentsOf: target.appendingPathComponent("debug/app"), encoding: .utf8), "binary")

    try engine.release(target.path)
    XCTAssertTrue(isRealDirectory(target.path))
    XCTAssertEqual(
      try String(contentsOf: target.appendingPathComponent("debug/app"), encoding: .utf8), "binary")
    XCTAssertTrue(engine.entries().isEmpty)
    let store = drive.appendingPathComponent(Engine.storeFolderName).appendingPathComponent(
      engine.installID)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), [])
  }

  func testRefusesWhatItMustNotMove() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    let outside = try s.dir("outside/node_modules")
    XCTAssertThrowsError(try engine.adopt(outside.path))
    XCTAssertThrowsError(try engine.adopt(code.path), "the root itself")
    try shell("/usr/bin/git", ["init", "-q"], in: code)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/.next/vendored.js")
    try shell("/usr/bin/git", ["add", "app/.next"], in: code)
    XCTAssertThrowsError(
      try engine.adopt(code.appendingPathComponent("app/.next").path), "tracked by git")
  }

  func testStorePathsCantEscape() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let store = s.root.appendingPathComponent("store")
    for bad in ["../x", "a/../../x", "/etc", "", "./x"] {
      XCTAssertThrowsError(try engine.storePath(bad, in: store), bad)
    }
    XCTAssertEqual(
      try engine.storePath("a/b", in: store).path, store.appendingPathComponent("a/b").path)
    XCTAssertNil(Engine.validated(store.path + "/../escape", in: store))
    XCTAssertNil(Engine.validated("/tmp/elsewhere", in: store))
    XCTAssertNotNil(Engine.validated(store.path + "/slot/d/node_modules/x", in: store))
  }

  func testNextBuildOutputGetsABackLink() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/node_modules/react/index.js")
    try s.file("code/app/.next/server/page.js")
    let next = code.appendingPathComponent("app/.next")
    try engine.adopt(next.path, kind: .next)
    let real = next.resolvingSymlinksInPath()
    let backLink = real.deletingLastPathComponent().appendingPathComponent("node_modules")
    XCTAssertEqual(
      try FileManager.default.destinationOfSymbolicLink(atPath: backLink.path),
      code.appendingPathComponent("app/node_modules").path)
  }

  /// A copy that fails partway (here, a file that can't be read) leaves the folder where it was,
  /// unrecorded, and nothing behind on the drive.
  func testAFailedCopyLeavesNothingOnTheDrive() throws {
    let s = try Scratch()
    let (engine, code, drive) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    let unreadable = try s.file("code/app/.next/secret.js", "x")
    XCTAssertEqual(chmod(unreadable.path, 0), 0)
    defer { chmod(unreadable.path, 0o600) }
    let next = code.appendingPathComponent("app/.next")

    XCTAssertThrowsError(try engine.adopt(next.path, kind: .next))
    XCTAssertTrue(isRealDirectory(next.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unreadable.path))
    XCTAssertTrue(engine.entries().isEmpty)
    let store = drive.appendingPathComponent(Engine.storeFolderName)
      .appendingPathComponent(engine.installID)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), [])
  }

  /// A folder that can't be read fails the copy (it used to be skipped silently, and the
  /// original deleted without it).
  func testAnUnreadableFolderFailsTheCopy() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/.next/locked/page.js", "x")
    let locked = code.appendingPathComponent("app/.next/locked")
    XCTAssertEqual(chmod(locked.path, 0o300), 0)
    defer { chmod(locked.path, 0o700) }
    let next = code.appendingPathComponent("app/.next")

    XCTAssertThrowsError(try engine.adopt(next.path, kind: .next))
    XCTAssertTrue(isRealDirectory(next.path))
    XCTAssertTrue(engine.entries().isEmpty)
  }

  /// A list of stowed folders that can't be read is never written over: stowing is refused
  /// and the file is left as it was.
  func testAnUnreadableListIsNeverOverwritten() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/.next/page.js", "x")
    let damaged = Data("[{\"id\": ".utf8)
    try damaged.write(to: engine.stateURL)

    XCTAssertNotNil(engine.listProblem)
    XCTAssertThrowsError(try engine.adopt(code.appendingPathComponent("app/.next").path))
    XCTAssertEqual(try Data(contentsOf: engine.stateURL), damaged)
    XCTAssertTrue(isRealDirectory(code.appendingPathComponent("app/.next").path))
  }

  /// An entry of a kind this version doesn't know still loads, so the rest of the list does.
  func testAnUnknownKindStillLoads() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let json = #"""
      [{"id": "a", "local": "/x/node_modules", "remote": "x-a", "online": true,
        "adoptedAt": 0, "kind": "something-new"}]
      """#
    try Data(json.utf8).write(to: engine.stateURL)
    XCTAssertNil(engine.listProblem)
    XCTAssertEqual(engine.entries().map(\.id), ["a"])
    XCTAssertNil(engine.entries().first?.kind)
  }

  /// A folder with stowed folders in it can't be removed (they'd be out of reach after a
  /// relaunch), unless another chosen folder covers them; once they're back, it can.
  func testARootHoldingStowedFoldersStays() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/.next/page.js", "x")
    let next = code.appendingPathComponent("app/.next").path
    try engine.adopt(next, kind: .next)

    XCTAssertThrowsError(try engine.revokeRoots([code.path]))
    XCTAssertEqual(engine.rootPaths, [code.path])
    try engine.grant(code.appendingPathComponent("app"), as: .root)
    XCTAssertNoThrow(try engine.revokeRoots([code.path]))
    try engine.release(next)
    XCTAssertNoThrow(try engine.revokeRoots([code.appendingPathComponent("app").path]))
    XCTAssertEqual(engine.rootPaths, [])
  }

  func testTheFreeLimitStopsNewOffloadsOnly() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/a/package.json", "{}")
    try s.file("code/a/.next/big", String(repeating: "x", count: 200_000))
    try s.file("code/b/package.json", "{}")
    try s.file("code/b/.next/big", String(repeating: "x", count: 200_000))
    let next = { (project: String) in code.appendingPathComponent("\(project)/.next").path }
    try engine.adopt(next("a"), kind: .next, limit: 300_000)
    XCTAssertThrowsError(try engine.adopt(next("b"), kind: .next, limit: 300_000)) {
      XCTAssertTrue($0 is OffloadLimitReached)
    }
    try engine.release(code.appendingPathComponent("a/.next").path)
    XCTAssertNoThrow(
      try engine.adopt(code.appendingPathComponent("b/.next").path, kind: .next, limit: 300_000))
  }

  func testDiscardDeletesBothCopies() throws {
    let s = try Scratch()
    let (engine, code, drive) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/.next/x", "x")
    try s.file("code/app/node_modules/a/package.json", "{}")
    let next = code.appendingPathComponent("app/.next").path
    let nm = code.appendingPathComponent("app/node_modules").path
    try engine.adopt(next, kind: .next)
    try engine.adopt(nm)
    try engine.discard(next)
    try engine.discard(nm)
    XCTAssertFalse(FileManager.default.fileExists(atPath: next))
    XCTAssertFalse(FileManager.default.fileExists(atPath: nm))
    let store = drive.appendingPathComponent(Engine.storeFolderName).appendingPathComponent(
      engine.installID)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), [])
    XCTAssertTrue(engine.entries().isEmpty)
  }

  func testAbandoningTheDriveLeavesLocalFoldersAndTheCopies() throws {
    let s = try Scratch()
    let (engine, code, drive) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/.next/x", "x")
    let next = code.appendingPathComponent("app/.next").path
    try engine.adopt(next, kind: .next)
    XCTAssertThrowsError(try engine.forgetDrive())
    try engine.abandonDrive()
    XCTAssertTrue(isRealDirectory(next))
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: next), [])
    XCTAssertTrue(engine.entries().isEmpty)
    XCTAssertFalse(engine.hasDrive)
    XCTAssertNil(engine.driveName)
    let store = drive.appendingPathComponent(Engine.storeFolderName).appendingPathComponent(
      engine.installID)
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: store.path).isEmpty)
  }

  func testRecountingCatchesGrowthOnTheDrive() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/app/package.json", "{}")
    try s.file("code/app/.next/small", "x")
    let next = code.appendingPathComponent("app/.next")
    try engine.adopt(next.path, kind: .next)
    let before = engine.offloadedBytes
    // A build writes through the link, onto the drive.
    try Data(count: 2_000_000).write(to: next.appendingPathComponent("big"))
    XCTAssertEqual(engine.offloadedBytes, before)
    engine.recountStowed()
    XCTAssertGreaterThan(engine.offloadedBytes, before + 1_900_000)
  }
}
