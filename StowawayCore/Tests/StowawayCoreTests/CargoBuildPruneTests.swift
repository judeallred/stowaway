import Darwin
import Foundation
import XCTest

@testable import StowawayCore

/// Clearing Cargo's shared build folder of projects no build uses any more.
final class CargoBuildPruneTests: XCTestCase {
  private let old = Int(Date().addingTimeInterval(-40 * 86_400).timeIntervalSince1970)

  /// A project's folder in the shared build folder, as Cargo lays it out; `aged` dates every
  /// folder and file in it 40 days back.
  @discardableResult
  private func project(_ s: Scratch, _ path: String, aged: Bool) throws -> URL {
    let root = "code/.cargo/stowaway-build/\(path)"
    try write(randomData(70_000), to: s.path("\(root)/debug/deps/libx.rlib"))
    try s.file("\(root)/debug/.fingerprint/x/dep-lib")
    try s.file("\(root)/debug/.cargo-lock")
    if aged {
      // Deepest first: dating a folder's contents changes the folder's date.
      for rel in [
        "debug/.fingerprint/x/dep-lib", "debug/.fingerprint/x", "debug/deps/libx.rlib",
        "debug/.fingerprint", "debug/deps", "debug/.cargo-lock", "debug", "",
      ] {
        setModified(s.path("\(root)/\(rel)"), old)
      }
    }
    return s.root.appendingPathComponent(root)
  }

  private var folder: (Scratch) -> URL {
    { $0.root.appendingPathComponent("code/.cargo/stowaway-build") }
  }

  func testUnusedProjectsGoAndRecentOnesStay() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let gone = try project(s, "11/aaaa", aged: true)
    let alsoGone = try project(s, "22/cccc", aged: true)
    let kept = try project(s, "11/bbbb", aged: false)

    let result = engine.pruneCargoBuildFolder(folder(s))

    XCTAssertEqual(result.folders, 2)
    XCTAssertGreaterThan(result.bytes, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: gone.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: alsoGone.path))
    XCTAssertFalse(
      FileManager.default.fileExists(atPath: folder(s).appendingPathComponent("22").path),
      "an emptied group goes too")
    XCTAssertTrue(FileManager.default.fileExists(atPath: kept.path))
  }

  /// One recent change anywhere in its profiles keeps a project.
  func testARecentBuildKeepsAProject() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let project = try project(s, "11/aaaa", aged: true)
    try write(randomData(10), to: project.appendingPathComponent("debug/deps/libnew.rlib").path)
    XCTAssertEqual(engine.pruneCargoBuildFolder(folder(s)).folders, 0)
  }

  func testAProjectABuildHoldsIsKept() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let project = try project(s, "11/aaaa", aged: true)
    let fd = open(project.appendingPathComponent("debug/.cargo-lock").path, O_RDONLY)
    defer { close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)
    XCTAssertEqual(engine.pruneCargoBuildFolder(folder(s)).folders, 0)
    flock(fd, LOCK_UN)
    XCTAssertEqual(engine.pruneCargoBuildFolder(folder(s)).folders, 1)
  }

  /// Stowed, its projects are on the drive: they go from there, and from the index.
  func testAStowedFoldersProjectsGoFromTheDrive() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let bytes = randomData(80_000)
    try project(s, "11/aaaa", aged: false)
    try project(s, "22/bbbb", aged: false)
    for project in ["11/aaaa", "22/bbbb"] {
      try write(
        bytes, to: s.path("code/.cargo/stowaway-build/\(project)/debug/deps/libshared.rlib"))
    }
    try engine.adopt(folder(s).path, kind: .cargoBuild)
    XCTAssertEqual(engine.sweepSharedFiles(eager).filesShared, 1)
    XCTAssertGreaterThan(engine.savedBySharing(), 0)

    // Nothing builds the first project any more.
    let gone = canonicalPath(folder(s).appendingPathComponent("11/aaaa").path)
    for rel in [
      "debug/.fingerprint/x/dep-lib", "debug/.fingerprint/x", "debug/deps/libx.rlib",
      "debug/deps/libshared.rlib", "debug/.fingerprint", "debug/deps", "debug/.cargo-lock",
      "debug", "",
    ] {
      setModified(gone + "/" + rel, old)
    }
    XCTAssertEqual(engine.pruneCargoBuildFolder(folder(s)).folders, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: gone))
    XCTAssertTrue(isSymlink(folder(s).path), "still stowed")
    XCTAssertEqual(engine.savedBySharing(), 0, "its twin shares with nothing now")
  }

  /// While the drive is away the folder is a stand-in: left alone.
  func testAStandInWhileTheDriveIsAwayIsLeftAlone() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    try project(s, "11/aaaa", aged: true)
    try engine.adopt(folder(s).path, kind: .cargoBuild)
    var entries = engine.entries()
    entries[0].online = false
    try engine.save(entries)
    XCTAssertEqual(engine.pruneCargoBuildFolder(folder(s)).folders, 0)
  }
}
