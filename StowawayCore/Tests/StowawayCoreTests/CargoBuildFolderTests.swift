import Foundation
import XCTest

@testable import StowawayCore

final class CargoBuildFolderTests: XCTestCase {
  private let dir = "/Users/me/.cargo/stowaway-build/{workspace-path-hash}"
  private var line: String { "build.build-dir = \"\(dir)\"  \(CargoBuildFolder.marker)" }

  func testAnEmptyConfigGetsOneTopLevelLine() throws {
    let on = try CargoBuildFolder.turningOn("", setting: dir)
    XCTAssertEqual(on, line + "\n")
    XCTAssertTrue(CargoBuildFolder.isOn(in: on))
    XCTAssertEqual(CargoBuildFolder.turningOff(on), "")
  }

  /// Added before any table, so it's at the top level; everything else stays as it was.
  func testOtherSettingsAreKept() throws {
    let config = """
      # mine
      [net]
      git-fetch-with-cli = true

      [target.aarch64-apple-darwin]
      rustflags = ["-C", "target-cpu=native"] # fast
      """
    let on = try CargoBuildFolder.turningOn(config, setting: dir)
    XCTAssertEqual(on, line + "\n" + config + "\n")
    XCTAssertEqual(CargoBuildFolder.turningOff(on), config + "\n")
  }

  /// With a [build] table, the line goes inside it (a top-level dotted key would define the
  /// table twice).
  func testAnExistingBuildTableGetsTheLine() throws {
    let config = "[build]\njobs = 8\n\n[net]\noffline = false\n"
    let on = try CargoBuildFolder.turningOn(config, setting: dir)
    XCTAssertEqual(
      on,
      "[build]\nbuild-dir = \"\(dir)\"  \(CargoBuildFolder.marker)\njobs = 8\n\n[net]\noffline = false\n"
    )
    XCTAssertEqual(CargoBuildFolder.turningOff(on), config)
  }

  func testTurningOnTwiceLeavesOneLine() throws {
    let once = try CargoBuildFolder.turningOn("[build]\njobs = 8\n", setting: dir)
    XCTAssertEqual(try CargoBuildFolder.turningOn(once, setting: dir), once)
  }

  func testTheUsersOwnBuildDirIsNeverTouched() {
    for config in [
      "[build]\nbuild-dir = \"/elsewhere\"\n",
      "build.build-dir = \"/elsewhere\"\n",
      "[build]\n\"build-dir\" = '/elsewhere'\n",
      "build = { jobs = 8 }\n",
    ] {
      XCTAssertThrowsError(try CargoBuildFolder.turningOn(config, setting: dir), config)
      XCTAssertFalse(CargoBuildFolder.isOn(in: config))
      XCTAssertEqual(CargoBuildFolder.turningOff(config), config)
    }
  }

  /// A build-dir in another table, a `#` in a string and a commented-out line aren't settings.
  func testLookalikesArentMistakenForTheSetting() throws {
    let config = """
      # build.build-dir = "/old"
      [alias]
      b = "build # build-dir = x"
      [profile.dev.build-override]
      opt-level = 3
      """
    XCTAssertNoThrow(try CargoBuildFolder.turningOn(config, setting: dir))
  }

  func testTheOlderConfigFileIsUsedWhenItsThere() throws {
    let s = try Scratch()
    let home = try s.dir(".cargo")
    XCTAssertEqual(CargoBuildFolder.configFile(in: home).lastPathComponent, "config.toml")
    try s.file(".cargo/config", "")
    XCTAssertEqual(CargoBuildFolder.configFile(in: home).lastPathComponent, "config")
  }

  /// The shared folder's Cargo lock is two levels down, under each project's hash.
  func testABuildInTheSharedFolderIsSeen() throws {
    let s = try Scratch()
    try s.file("build/58/049bedfae8f2c1/debug/.cargo-lock")
    let lock = s.root.appendingPathComponent("build/58/049bedfae8f2c1/debug/.cargo-lock").path
    let candidate = Candidate(
      kind: .cargoBuild, path: s.root.appendingPathComponent("build").path, project: nil)
    XCTAssertFalse(Measure.isBusy(candidate))
    let fd = open(lock, O_RDONLY)
    defer { close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)
    XCTAssertTrue(Measure.isBusy(candidate))
  }
}
