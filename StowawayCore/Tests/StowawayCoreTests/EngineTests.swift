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
}
