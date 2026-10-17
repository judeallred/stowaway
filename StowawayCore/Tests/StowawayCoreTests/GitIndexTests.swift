import Foundation
import XCTest

@testable import StowawayCore

final class GitIndexTests: XCTestCase {
  private func repo(indexVersion: Int) throws -> Scratch {
    let s = try Scratch()
    try shell("/usr/bin/git", ["init", "-q"], in: s.root)
    try s.file("app/package.json", "{}")
    try s.file("app/node_modules/left-pad/index.js", "x")
    try s.file("committed/node_modules/vendored/index.js", "x")
    try s.file("deep/a/very/long/path/that/shares/a/prefix/file.txt", "x")
    try s.file("deep/a/very/long/path/that/shares/another/file.txt", "x")
    try shell("/usr/bin/git", ["add", "app/package.json", "committed", "deep"], in: s.root)
    try shell("/usr/bin/git", ["update-index", "--index-version", "\(indexVersion)"], in: s.root)
    return s
  }

  func testTrackedAndUntrackedFolders() throws {
    for version in [2, 3, 4] {
      let s = try repo(indexVersion: version)
      XCTAssertEqual(
        GitIndex.tracking(of: s.root.appendingPathComponent("app/node_modules")), .untracked,
        "v\(version)")
      XCTAssertEqual(
        GitIndex.tracking(of: s.root.appendingPathComponent("committed/node_modules")), .tracked,
        "v\(version)")
      XCTAssertEqual(
        GitIndex.tracking(
          of: s.root.appendingPathComponent("deep/a/very/long/path/that/shares/another")), .tracked,
        "v\(version) prefix compression")
      // A name that merely starts like a tracked folder isn't inside it.
      XCTAssertEqual(
        GitIndex.tracking(of: s.root.appendingPathComponent("committed/node")), .untracked,
        "v\(version)")
    }
  }

  func testOutsideARepositoryIsUntracked() throws {
    let s = try Scratch()
    try s.file("x/node_modules/a.js")
    XCTAssertEqual(
      GitIndex.tracking(of: s.root.appendingPathComponent("x/node_modules")), .untracked)
  }

  func testUnreadableIndexIsUnknown() throws {
    let s = try Scratch()
    try s.file(".git/index", "not an index")
    try s.dir("x/node_modules")
    XCTAssertEqual(GitIndex.tracking(of: s.root.appendingPathComponent("x/node_modules")), .unknown)
  }

  func testWorktreeGitFile() throws {
    let s = try repo(indexVersion: 2)
    try shell(
      "/usr/bin/git", ["-c", "user.email=t@t", "-c", "user.name=t", "commit", "-qm", "x"],
      in: s.root)
    try shell("/usr/bin/git", ["worktree", "add", "-q", "wt"], in: s.root)
    XCTAssertEqual(
      GitIndex.tracking(of: s.root.appendingPathComponent("wt/committed/node_modules")), .tracked)
    XCTAssertEqual(
      GitIndex.tracking(of: s.root.appendingPathComponent("wt/app/node_modules")), .untracked)
  }
}
