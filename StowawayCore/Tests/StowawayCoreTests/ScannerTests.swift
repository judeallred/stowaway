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

  /// The project App Review creates with docs/app-store/review-project.sh (its commands are in
  /// the review notes) has a node_modules and Cargo build files for Stowaway to find.
  func testTheReviewProjectIsFound() throws {
    let s = try Scratch()
    let script = URL(fileURLWithPath: #filePath)
      .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
      .deletingLastPathComponent().appendingPathComponent("docs/app-store/review-project.sh")
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = [script.path]
    process.environment = ["HOME": s.root.path, "PATH": "/usr/bin:/bin"]
    try process.run()
    process.waitUntilExit()
    XCTAssertEqual(process.terminationStatus, 0)
    let root = s.root.appendingPathComponent("Stowaway Review")
    let found = Scanner().scan(roots: [root.path]).map(\.kind)
    XCTAssertEqual(found.sorted { $0.rawValue < $1.rawValue }, [.cargoTarget, .node])
    XCTAssertGreaterThan(
      Measure.allocatedSize(root.appendingPathComponent("web-app/node_modules").path), 10_000_000)
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

final class MixedCargoTests: XCTestCase {
  func testFindsOnlyCachesAndPreservesMixedOutputs() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/rs/Cargo.toml")
    try s.file("code/rs/target/notes.json", "precious")
    for profile in ["debug", "experiment/debug", "worktree/target/release"] {
      for part in ["deps", "incremental", "build", ".fingerprint"] {
        try s.file("code/rs/target/\(profile)/\(part)/data", "cache")
      }
      try s.file("code/rs/target/\(profile)/app", "executable")
    }
    try s.file("code/rs/target/worktree/Cargo.toml", "source")
    try s.file("code/rs/target/unidentified/deps/data", "not enough evidence")
    try s.file("code/rs/target/ignored/.stowaway-ignore")
    try s.dir("code/rs/target/ignored/debug/.fingerprint")
    try s.dir("code/rs/target/ignored/debug/deps")
    let found = Scanner().scan(roots: [code.path])
    XCTAssertEqual(found.count, 9)
    XCTAssertTrue(found.allSatisfy { $0.kind == .cargoCache })
    for candidate in found {
      try engine.adopt(candidate.path, kind: candidate.kind)
    }
    XCTAssertEqual(engine.entries().count, 9)
    XCTAssertEqual(
      Set(Scanner().scan(roots: [code.path])), Set(found),
      "Stowed parts retain their owning project and remain discoverable without following links")
    for candidate in found { try engine.release(candidate.path) }
    // Deletion is limited to identified caches, leaving source and executables alone.
    for candidate in found {
      try Cleaner().delete(candidate, roots: [code.path], offloaded: [])
    }
    for path in ["notes.json", "debug/app", "worktree/Cargo.toml", "unidentified/deps/data"] {
      XCTAssertTrue(FileManager.default.fileExists(atPath: s.path("code/rs/target/" + path)))
    }
  }

  func testCargoCacheRevalidatesAndHonorsLocksAndGit() throws {
    let s = try Scratch()
    try s.file("rs/Cargo.toml")
    try s.file("rs/target/debug/deps/data")
    let marker = try s.dir("rs/target/debug/.fingerprint")
    let c = Candidate(
      kind: .cargoCache, path: s.path("rs/target/debug/deps"), project: s.path("rs"))
    XCTAssertNil(Cleaner().refusal(c, roots: [s.root.path], offloaded: []))
    try FileManager.default.removeItem(at: marker)
    XCTAssertNotNil(Cleaner().refusal(c, roots: [s.root.path], offloaded: []))
    let lock = try s.file("rs/target/debug/.cargo-lock")
    let fd = open(lock.path, O_RDWR)
    defer { close(fd) }
    XCTAssertEqual(flock(fd, LOCK_EX), 0)
    XCTAssertTrue(Measure.isBusy(c))
    flock(fd, LOCK_UN)
    try shell("/usr/bin/git", ["init", "-q"], in: s.root)
    try shell("/usr/bin/git", ["add", "."], in: s.root)
    XCTAssertNotNil(Cleaner().refusal(c, roots: [s.root.path], offloaded: []))
  }
}

final class WorktreeLocationTests: XCTestCase {
  func testCommonWorktreesAreIndependentInFullAndPartialScans() throws {
    let s = try Scratch()
    try s.file("repo/package.json", "{}")
    try s.dir("repo/node_modules/a")
    for location in Scanner.checkoutFolders {
      let path = "repo/" + location + "/fix"
      try s.file(path + "/package.json", "{}")
      try s.dir(path + "/node_modules/b")
    }
    let roots = [s.root.path]
    let full = Set(Scanner().scan(roots: roots).map(\.path))
    XCTAssertEqual(full.count, Scanner.checkoutFolders.count + 1)
    for location in Scanner.checkoutFolders {
      let path = s.path("repo/" + location + "/fix")
      XCTAssertTrue(full.contains(path + "/node_modules"))
      XCTAssertEqual(
        Scanner().scan(folder: path, roots: roots).map(\.path), [path + "/node_modules"])
    }
  }

  func testWorktreeContainersRespectIgnoresAndSymlinkBoundaries() throws {
    let s = try Scratch()
    try s.file("outside/fix/package.json", "{}")
    try s.dir("outside/fix/node_modules/a")
    try s.dir("repo/.cursor")
    try s.file("repo/.cursor/.stowaway-ignore")
    try s.file("repo/.cursor/worktrees/fix/package.json", "{}")
    try s.dir("repo/.cursor/worktrees/fix/node_modules/a")
    try s.dir("repo/.claude")
    try FileManager.default.createSymbolicLink(
      atPath: s.path("repo/.claude/worktrees"), withDestinationPath: s.path("outside"))
    XCTAssertEqual(Scanner().scan(roots: [s.path("repo")]), [])
    for path in ["repo/.cursor/worktrees/fix", "repo/.claude/worktrees/fix"] {
      XCTAssertEqual(Scanner().scan(folder: s.path(path), roots: [s.path("repo")]), [])
    }
  }

  func testHiddenCheckoutRootsAreWalkable() {
    let home = realHomeDirectory.path
    for location in [".cursor/worktrees", ".codex/worktrees", ".t3/worktrees"] {
      let root = home + "/" + location
      XCTAssertEqual(Scanner.walkable([root]), [root])
    }
  }
}

final class DownloadCacheTests: XCTestCase {
  func testPnpmDownloadCacheLifecycleAndIgnore() throws {
    try checkLifecycle(.pnpmCache)
  }

  func testBrowserDownloadCacheLifecycleAndIgnore() throws {
    try checkLifecycle(.browserDownloads)
  }

  private func checkLifecycle(_ kind: Kind) throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    let home = try s.dir("code/home")
    for relative in kind.defaultLocations {
      let cache = home.appendingPathComponent(relative)
      try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
      try Data("downloaded".utf8).write(to: cache.appendingPathComponent("data"))
      let candidates = Scanner().caches(roots: [home.path], home: home).filter { $0.kind == kind }
      XCTAssertTrue(candidates.contains { $0.path == cache.path })
      let candidate = try XCTUnwrap(candidates.first { $0.path == cache.path })
      try engine.adopt(cache.path, kind: kind)
      XCTAssertTrue(isSymlink(cache.path))
      try engine.release(cache.path)
      XCTAssertEqual(
        try String(contentsOf: cache.appendingPathComponent("data"), encoding: .utf8), "downloaded")
      try Cleaner().delete(candidate, roots: [code.path], offloaded: [])
      XCTAssertTrue(isRealDirectory(cache.path))
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cache.path), [])
      try Data().write(to: cache.appendingPathComponent(Scanner.ignoreMarker))
      XCTAssertFalse(
        Scanner().caches(roots: [home.path], home: home).contains { $0.path == cache.path })
      XCTAssertFalse(
        Scanner().caches(roots: [s.path("ungranted")], home: home).contains {
          $0.path == cache.path
        })
    }
  }
}

final class ScopedScanRegressionTests: XCTestCase {
  func testDeepWorktreeUsesSameDepthForFullAndPartialScans() throws {
    let s = try Scratch()
    let project = "repo/.claude/worktrees/fix/web"
    try s.file(project + "/package.json", "{}")
    try s.dir(project + "/node_modules/a")
    var scanner = Scanner()
    scanner.maxDepth = 3
    let full = scanner.scan(roots: [s.root.path])
    XCTAssertEqual(full.map(\.path), [s.path(project + "/node_modules")])
    XCTAssertEqual(scanner.scan(folder: s.path(project), roots: [s.root.path]), full)
    scanner.maxDepth = 2
    XCTAssertEqual(scanner.scan(roots: [s.root.path]), [])
    XCTAssertEqual(scanner.scan(folder: s.path(project), roots: [s.root.path]), [])
  }

  func testMixedCargoPartialScanKeepsFullScanKindsAndOwners() throws {
    let s = try Scratch()
    try s.file("repo/Cargo.toml")
    try s.file("repo/target/nested/Cargo.toml")
    try s.file("repo/target/nested/target/CACHEDIR.TAG")
    for profile in ["repo/target/debug", "repo/target/nested/target/release"] {
      try s.dir(profile + "/.fingerprint")
      try s.dir(profile + "/deps")
      try s.dir(profile + "/build")
    }
    let roots = [s.root.path]
    let full = Scanner().scan(roots: roots)
    XCTAssertEqual(full.count, 4)
    for folder in [
      "repo/target", "repo/target/debug", "repo/target/nested",
      "repo/target/nested/target/release/deps",
    ] {
      let path = s.path(folder)
      let expected = full.filter { $0.path == path || $0.path.hasPrefix(path + "/") }
      XCTAssertEqual(Set(Scanner().scan(folder: path, roots: roots)), Set(expected), folder)
    }
  }

  func testSymlinkRootIsNotTraversedByEitherScan() throws {
    let s = try Scratch()
    try s.file("actual/package.json", "{}")
    try s.dir("actual/node_modules/a")
    try FileManager.default.createSymbolicLink(
      atPath: s.path("link"), withDestinationPath: s.path("actual"))
    XCTAssertEqual(Scanner().scan(roots: [s.path("link")]), [])
    XCTAssertEqual(Scanner().scan(folder: s.path("link"), roots: [s.path("link")]), [])
  }
}
