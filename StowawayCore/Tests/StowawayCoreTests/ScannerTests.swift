import Foundation
import XCTest

@testable import StowawayCore

final class ScannerTests: XCTestCase {
  private func found(_ s: Scratch) -> [String: Kind] {
    var out: [String: Kind] = [:]
    for c in Scanner().scan(roots: [s.root.path]) {
      out[String(c.path.dropFirst(s.root.path.count + 1))] = c.kind
    }
    return out
  }

  func testFindsProjectsAndRespectsRules() throws {
    let s = try Scratch()
    try s.file("web/package.json", "{}")
    try s.file("web/node_modules/react/index.js")
    // A workspace package inside a project with node_modules is left to the outer one.
    try s.file("web/packages/ui/package.json", "{}")
    try s.file("web/packages/ui/node_modules/x/index.js")
    try s.file("rs/Cargo.toml")
    try s.file("rs/target/CACHEDIR.TAG")
    // No CACHEDIR.TAG: not Cargo's.
    try s.file("other/Cargo.toml")
    try s.dir("other/target/stuff")
    // Redirected target-dir: Cargo builds elsewhere.
    try s.file("redirected/Cargo.toml")
    try s.file("redirected/.cargo/config.toml", "[build]\ntarget-dir = \"/tmp/x\"\n")
    try s.file("redirected/target/CACHEDIR.TAG")
    try s.file("py/pyproject.toml")
    try s.file("py/.venv/pyvenv.cfg")
    try s.file("notvenv/pyproject.toml")
    try s.dir("notvenv/.venv/lib")
    try s.file("next/package.json", "{}")
    try s.dir("next/.next/cache")
    try s.file("ignored/.stowaway-ignore")
    try s.file("ignored/app/package.json", "{}")
    try s.dir("ignored/app/node_modules/x")
    // No manifest: not a project.
    try s.dir("loose/node_modules/x")

    XCTAssertEqual(
      found(s),
      [
        "web/node_modules": .node, "rs/target": .cargoTarget, "py/.venv": .venv,
        "next/.next": .next,
      ])
  }

  func testSymlinkedFoldersAreLeftToTheEngine() throws {
    let s = try Scratch()
    try s.file("web/package.json", "{}")
    let elsewhere = try s.dir("elsewhere/node_modules")
    try FileManager.default.createSymbolicLink(
      at: s.root.appendingPathComponent("web/node_modules"), withDestinationURL: elsewhere)
    XCTAssertEqual(found(s), [:])
  }

  func testClaudeWorktreesAreSeparateProjects() throws {
    let s = try Scratch()
    try s.file("web/package.json", "{}")
    try s.file("web/node_modules/react/index.js")
    try s.file("web/.claude/worktrees/fix/package.json", "{}")
    try s.file("web/.claude/worktrees/fix/node_modules/react/index.js")
    XCTAssertEqual(
      found(s), ["web/node_modules": .node, "web/.claude/worktrees/fix/node_modules": .node])
  }

  func testCargoAndXcodeParts() throws {
    let s = try Scratch()
    for profile in ["debug", "release", "aarch64-apple-darwin/debug"] {
      for part in ["deps", "incremental", "build", ".fingerprint"] {
        try s.dir("target/\(profile)/\(part)")
      }
    }
    let parts = Kind.cargoTarget.parts(of: s.root.appendingPathComponent("target"))?.map {
      String($0.path.dropFirst(s.root.path.count + 1))
    }
    XCTAssertEqual(
      parts?.sorted(),
      [
        "target/aarch64-apple-darwin/debug/build", "target/aarch64-apple-darwin/debug/deps",
        "target/aarch64-apple-darwin/debug/incremental", "target/debug/build", "target/debug/deps",
        "target/debug/incremental", "target/release/build", "target/release/deps",
        "target/release/incremental",
      ])

    try s.dir("DerivedData/ModuleCache.noindex")
    try s.dir("DerivedData/App-abc/Build/Intermediates.noindex")
    try s.dir("DerivedData/App-abc/Build/Products/Debug")
    try s.dir("DerivedData/App-abc/Index.noindex")
    let xcode = Kind.xcodeDerivedData.parts(of: s.root.appendingPathComponent("DerivedData"))?.map {
      String($0.path.dropFirst(s.root.path.count + 1))
    }
    XCTAssertEqual(
      xcode,
      [
        "DerivedData/ModuleCache.noindex", "DerivedData/App-abc/Build/Intermediates.noindex",
        "DerivedData/App-abc/Index.noindex",
      ])
  }

  func testCleanerGuards() throws {
    let s = try Scratch()
    try shell("/usr/bin/git", ["init", "-q"], in: s.root)
    try s.file("web/package.json", "{}")
    try s.file("web/node_modules/a/index.js", "x")
    try s.file("vendored/package.json", "{}")
    try s.file("vendored/node_modules/b/index.js", "x")
    try shell("/usr/bin/git", ["add", "vendored"], in: s.root)
    let cleaner = Cleaner()
    let roots = [s.root.path]
    let web = Candidate(kind: .node, path: s.path("web/node_modules"), project: s.path("web"))
    let vendored = Candidate(
      kind: .node, path: s.path("vendored/node_modules"), project: s.path("vendored"))
    XCTAssertNotNil(cleaner.refusal(vendored, roots: roots, offloaded: []))
    XCTAssertNotNil(cleaner.refusal(web, roots: ["/somewhere/else"], offloaded: []))
    let entry = Entry(id: "x", local: web.path, remote: "x", online: true, adoptedAt: Date())
    XCTAssertNotNil(cleaner.refusal(web, roots: roots, offloaded: [entry]))
    try cleaner.delete(web, roots: roots, offloaded: [])
    XCTAssertFalse(FileManager.default.fileExists(atPath: web.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: s.path("web/package.json")))
  }

  func testTheSampleProjectIsFoundAndSafeToTry() throws {
    let s = try Scratch()
    let root = try SampleProject.create(in: s.root)
    let found = Scanner().scan(roots: [root.path]).map { ($0.kind, $0.url.lastPathComponent) }
    XCTAssertEqual(found.map(\.0).sorted { $0.rawValue < $1.rawValue }, [.cargoTarget, .node])
    XCTAssertGreaterThan(
      Measure.allocatedSize(root.appendingPathComponent("web-app/node_modules").path), 10_000_000)
    XCTAssertThrowsError(try SampleProject.create(in: s.root), "won't overwrite")
  }

  func testARunningCargoBuildIsBusy() throws {
    let s = try Scratch()
    try s.file("rs/Cargo.toml")
    try s.file("rs/target/CACHEDIR.TAG")
    let lock = try s.file("rs/target/debug/.cargo-lock")
    let candidate = Candidate(kind: .cargoTarget, path: s.path("rs/target"), project: s.path("rs"))
    XCTAssertFalse(Measure.isBusy(candidate))
    let fd = open(lock.path, O_RDWR)
    defer { close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)
    XCTAssertTrue(Measure.isBusy(candidate), "cargo holds this lock while building")
  }

  func testActivityTwoLevelsDownCounts() throws {
    let s = try Scratch()
    try s.file("rs/Cargo.toml")
    try s.file("rs/target/debug/deps/old.rlib")
    let candidate = Candidate(kind: .cargoTarget, path: s.path("rs/target"), project: s.path("rs"))
    let old = Date(timeIntervalSinceNow: -3600)
    for path in [
      "rs/Cargo.toml", "rs/target", "rs/target/debug", "rs/target/debug/deps",
      "rs/target/debug/deps/old.rlib",
    ] {
      try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: s.path(path))
    }
    XCTAssertLessThan(Measure.lastActivity(of: candidate), Date(timeIntervalSinceNow: -3000))
    try s.file("rs/target/debug/deps/new.rlib")
    XCTAssertGreaterThan(Measure.lastActivity(of: candidate), Date(timeIntervalSinceNow: -60))
  }
}

final class DriveSpeedTests: XCTestCase {
  func testMeasuresAndCleansUp() throws {
    let store = FileManager.default.temporaryDirectory.appendingPathComponent(
      "speed-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: store) }
    // A leftover from a crashed run is swept.
    try FileManager.default.createDirectory(
      at: store.appendingPathComponent(".stowaway-speedtest-old"),
      withIntermediateDirectories: false)
    let speed = try DriveSpeed.measure(in: store, bytes: 16 << 20, smallFiles: 100)
    XCTAssertGreaterThan(speed.writeMBps, 0)
    XCTAssertGreaterThan(speed.readMBps, 0)
    XCTAssertGreaterThan(speed.smallFilesPerSecond, 0)
    XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: store.path), [])
  }
}

final class ScannerSkipTests: XCTestCase {
  func testPackagesAreNotWalked() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "skip-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    for dir in ["Thing.app/web", "Photos.photoslibrary/web", "code/web"] {
      let web = root.appendingPathComponent(dir)
      try FileManager.default.createDirectory(
        at: web.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
      try "{}".write(
        to: web.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
    }
    let found = Scanner().scan(roots: [root.path]).map(\.path)
    XCTAssertEqual(found, [root.appendingPathComponent("code/web/node_modules").path])
  }
}

final class WalkableRootTests: XCTestCase {
  func testCacheFoldersAndNestedRootsArentWalked() {
    let home = realHomeDirectory.standardizedFileURL.path
    let roots = [
      "\(home)/code", "\(home)/code/work", "\(home)/.cargo", "\(home)/Library/Caches",
      "\(home)/Library/Developer/Xcode", "/Volumes/Work/src",
    ]
    XCTAssertEqual(Scanner.walkable(roots), ["\(home)/code", "/Volumes/Work/src"])
  }
}

final class PartialScanTests: XCTestCase {
  /// Scanning one changed folder finds what the full scan would there, and nothing it wouldn't.
  func testAChangedFolderScansLikeTheFullScan() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "partial-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    func make(_ rel: String) throws {
      try FileManager.default.createDirectory(
        at: root.appendingPathComponent(rel), withIntermediateDirectories: true)
    }
    func file(_ rel: String) throws {
      try make((rel as NSString).deletingLastPathComponent)
      try "{}".write(to: root.appendingPathComponent(rel), atomically: true, encoding: .utf8)
    }
    // A monorepo: its packages' own node_modules belong to the project's.
    try file("mono/package.json")
    try make("mono/node_modules/a")
    try file("mono/packages/web/package.json")
    try make("mono/packages/web/node_modules/b")
    // A workspace directly under its project: the parent is the node project.
    try file("mono/web/package.json")
    try make("mono/web/node_modules/d")
    // A new standalone project.
    try file("fresh/package.json")
    try make("fresh/node_modules/c")
    // A project under a folder marked to be left alone.
    try file("ignored/.stowaway-ignore")
    try file("ignored/app/package.json")
    try make("ignored/app/node_modules/e")
    let roots = [root.path]
    let full = Set(Scanner().scan(roots: roots).map(\.path))
    let web = root.appendingPathComponent("mono/packages/web").path
    let fresh = root.appendingPathComponent("fresh").path
    XCTAssertEqual(Scanner().scan(folder: web, roots: roots).map(\.path), [])
    let direct = root.appendingPathComponent("mono/web").path
    XCTAssertEqual(Scanner().scan(folder: direct, roots: roots).map(\.path), [])
    XCTAssertFalse(full.contains(direct + "/node_modules"))
    let ignored = root.appendingPathComponent("ignored/app").path
    XCTAssertEqual(Scanner().scan(folder: ignored, roots: roots).map(\.path), [])
    XCTAssertFalse(full.contains(ignored + "/node_modules"))
    XCTAssertEqual(
      Scanner().scan(folder: fresh, roots: roots).map(\.path), [fresh + "/node_modules"])
    XCTAssertTrue(full.contains(fresh + "/node_modules"))
    XCTAssertFalse(full.contains(web + "/node_modules"))
  }
}
