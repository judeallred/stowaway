import Foundation
import XCTest

@testable import StowawayCore

final class DeepLinkTests: XCTestCase {
  /// A small npm-style tree: a scoped package, a package with a nested node_modules, a hidden
  /// lockfile and a .bin link.
  private func project(_ s: Scratch) throws -> URL {
    try s.file("code/app/package.json", #"{ "name": "app", "dependencies": { "a": "1" } }"#)
    try s.file("code/app/node_modules/a/package.json", #"{ "name": "a", "version": "1.0.0" }"#)
    try s.file("code/app/node_modules/a/index.js", "module.exports = require('b')")
    try s.file(
      "code/app/node_modules/a/node_modules/b/package.json", #"{ "name": "b", "version": "1.0.0" }"#
    )
    try s.file("code/app/node_modules/b/package.json", #"{ "name": "b", "version": "2.0.0" }"#)
    try s.file("code/app/node_modules/@scope/c/package.json", #"{ "name": "@scope/c" }"#)
    try s.file("code/app/node_modules/@scope/c/dist/c.js", "c")
    try s.file("code/app/node_modules/.package-lock.json", "{}")
    try s.dir("code/app/node_modules/.bin")
    try FileManager.default.createSymbolicLink(
      atPath: s.path("code/app/node_modules/.bin/c"), withDestinationPath: "../@scope/c/dist/c.js")
    return s.root.appendingPathComponent("code/app/node_modules")
  }

  func testLayoutResolvesThroughTheLocalTree() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let nm = try project(s)
    var dirTimes = stat()
    lstat(nm.appendingPathComponent("a").path, &dirTimes)

    try engine.adopt(nm.path)

    let fm = FileManager.default
    // Package folders stay real; their contents are links.
    for pkg in ["a", "b", "@scope/c", "a/node_modules/b"] {
      let dir = nm.appendingPathComponent(pkg)
      XCTAssertTrue(isRealDirectory(dir.path), pkg)
      XCTAssertTrue(isSymlink(dir.appendingPathComponent("package.json").path), pkg)
    }
    XCTAssertTrue(
      isRealDirectory(nm.appendingPathComponent("a/node_modules").path),
      "nested node_modules stays real")
    XCTAssertTrue(isRealDirectory(nm.appendingPathComponent(".bin").path))
    XCTAssertTrue(
      isSymlink(nm.appendingPathComponent(".package-lock.json").path), "lockfile moved to the drive"
    )
    XCTAssertEqual(
      try String(contentsOf: nm.appendingPathComponent(".bin/c"), encoding: .utf8), "c")

    // a's real path is in the store under …/node_modules/a, and walking up from it reaches a's
    // own nested node_modules first (b@1), then the project's (b@2).
    let real = nm.appendingPathComponent("a/index.js").resolvingSymlinksInPath()
    XCTAssertTrue(real.path.contains("/node_modules/a/index.js"), real.path)
    let own = real.deletingLastPathComponent().appendingPathComponent("node_modules/b/package.json")
    XCTAssertTrue(try String(contentsOf: own, encoding: .utf8).contains("1.0.0"))
    // The private node_modules holding a, then the level above it, whose node_modules links back.
    let holder = real.deletingLastPathComponent().deletingLastPathComponent()
    let level = holder.deletingLastPathComponent().deletingLastPathComponent()
    let chain = try fm.destinationOfSymbolicLink(
      atPath: level.appendingPathComponent("node_modules").path)
    XCTAssertEqual(chain, nm.path)

    // npm's hidden-lockfile check needs package folders no newer than before.
    var after = stat()
    lstat(nm.appendingPathComponent("a").path, &after)
    XCTAssertEqual(after.st_mtimespec.tv_sec, dirTimes.st_mtimespec.tv_sec)

    try engine.release(nm.path)
    XCTAssertFalse(isSymlink(nm.appendingPathComponent("a/package.json").path))
    XCTAssertFalse(isSymlink(nm.appendingPathComponent(".package-lock.json").path))
    XCTAssertTrue(
      try String(
        contentsOf: nm.appendingPathComponent("a/node_modules/b/package.json"), encoding: .utf8
      ).contains("1.0.0"))
  }

  func testReinstalledPackagesAreReoffloadedAndUnchangedOnesRelinked() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let nm = try project(s)
    try engine.adopt(nm.path)
    // npm replaces b with an identical copy and adds d. npm gives every file it extracts the same
    // fixed date, so the copy's dates match the original's.
    let b = nm.appendingPathComponent("b")
    let manifest = b.appendingPathComponent("package.json")
    let date = try XCTUnwrap(
      FileManager.default.attributesOfItem(atPath: manifest.path)[.modificationDate] as? Date)
    try Copier.remove(b)
    try s.file("code/app/node_modules/b/package.json", #"{ "name": "b", "version": "2.0.0" }"#)
    try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: manifest.path)
    try s.file("code/app/node_modules/d/package.json", #"{ "name": "d" }"#)
    let stats = try engine.exclusively { () -> CopyStats in
      let store = try XCTUnwrap(engine.enterGrants()).appendingPathComponent(
        try XCTUnwrap(engine.entries().first).remote)
      return try engine.offloadPackages(local: nm, store: store)
    }
    XCTAssertEqual(stats.reused, 1, "b was identical")
    XCTAssertTrue(isSymlink(b.appendingPathComponent("package.json").path))
    XCTAssertTrue(isSymlink(nm.appendingPathComponent("d/package.json").path))
  }

  func testAManifestOnTheDriveCantPointOutside() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let nm = try project(s)
    try engine.adopt(nm.path)
    let store = try XCTUnwrap(engine.enterGrants()).appendingPathComponent(
      try XCTUnwrap(engine.entries().first).remote)
    // A tampered manifest names a folder outside the store for a package that no longer exists.
    let victim = try s.dir("victim")
    try s.file("victim/keep.txt", "precious")
    var manifest = Engine.readManifest(store)
    manifest["gone"] = victim.path
    manifest["also-gone"] = store.path + "/../../.."
    try Engine.writeManifest(manifest, to: store)
    engine.reconcile()
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: victim.appendingPathComponent("keep.txt").path))
  }

  /// The slots in the store (not the manifest).
  private func slots(_ store: URL) throws -> Set<String> {
    Set(
      try FileManager.default.contentsOfDirectory(atPath: store.path).filter { !$0.hasPrefix(".") })
  }

  /// An upgraded package moves to a new slot; the old one doesn't linger on the drive.
  func testUpgradedPackagesDontLeaveOldCopies() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let nm = try project(s)
    try engine.adopt(nm.path)
    let store = try XCTUnwrap(engine.enterGrants()).appendingPathComponent(
      try XCTUnwrap(engine.entries().first).remote)
    let before = try slots(store)
    let b = nm.appendingPathComponent("b")
    try Copier.remove(b)
    try s.file("code/app/node_modules/b/package.json", #"{ "name": "b", "version": "3.0.0" }"#)
    _ = try engine.exclusively { try engine.offloadPackages(local: nm, store: store) }
    XCTAssertEqual(try slots(store).count, before.count)
    XCTAssertTrue(isSymlink(b.appendingPathComponent("package.json").path))
  }

  /// Forgetting a drive that's gone leaves no links into its store: npm repairs the folder.
  func testAbandoningLeavesNoLinksIntoTheStore() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let nm = try project(s)
    try engine.adopt(nm.path)
    try engine.abandonDrive()
    let walker = try XCTUnwrap(FileManager.default.enumerator(atPath: nm.path))
    for case let rel as String in walker {
      let path = nm.appendingPathComponent(rel).path
      guard isSymlink(path) else { continue }
      let destination = try FileManager.default.destinationOfSymbolicLink(atPath: path)
      XCTAssertFalse(
        destination.contains(Engine.storeFolderName), "\(rel) still links to the store")
    }
  }

  /// Bringing back stops, keeping the store, if a link leads nowhere (the drive mounted under
  /// another name): deleting the store would lose those packages.
  func testReleaseStopsAtLinksThatLeadNowhere() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let nm = try project(s)
    try engine.adopt(nm.path)
    let store = try XCTUnwrap(engine.enterGrants()).appendingPathComponent(
      try XCTUnwrap(engine.entries().first).remote)
    let file = nm.appendingPathComponent("a/index.js")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.createSymbolicLink(
      atPath: file.path, withDestinationPath: "/Volumes/Gone/Stowaway.noindex/x/index.js")
    XCTAssertThrowsError(try engine.release(nm.path))
    XCTAssertTrue(isRealDirectory(store.path))
  }

  /// A pnpm project is recognized as one Stowaway can't stow, without trying.
  func testPnpmProjectsAreKnownUnstowable() throws {
    let s = try Scratch()
    let npm = try project(s)
    XCTAssertNil(Engine.refusal(forNodeModules: npm))
    try s.file("code/web/package.json", "{}")
    try s.file("code/web/pnpm-lock.yaml", "lockfileVersion: '9.0'")
    try s.file("code/web/node_modules/.pnpm/lock.yaml", "")
    XCTAssertNotNil(
      Engine.refusal(forNodeModules: s.root.appendingPathComponent("code/web/node_modules")))
  }

  /// A settled project isn't walked again until npm changes its top level; then it is, and
  /// what npm reinstalled goes back to the drive.
  func testReconcileSkipsSettledProjectsUntilNpmChangesThem() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let nm = try project(s)
    try engine.adopt(nm.path)
    engine.reconcile()
    let id = try XCTUnwrap(engine.entries().first).id
    XCTAssertNotNil(engine.settledChange(of: id), "settled after a quiet pass")
    // npm reinstalls b and rewrites its lockfile (replacing the link with a file).
    let b = nm.appendingPathComponent("b")
    try Copier.remove(b)
    try s.file("code/app/node_modules/b/package.json", #"{ "name": "b", "version": "2.1.0" }"#)
    let lockfile = nm.appendingPathComponent(".package-lock.json")
    try FileManager.default.removeItem(at: lockfile)
    try "{}".write(to: lockfile, atomically: true, encoding: .utf8)
    engine.reconcile()
    XCTAssertTrue(isSymlink(b.appendingPathComponent("package.json").path))
    XCTAssertTrue(isSymlink(lockfile.path))
  }

  /// A re-offload interrupted after moving a package's files aside, before linking them: the
  /// next launch puts them back rather than deleting them with the trash.
  func testAnInterruptedSwapLosesNoFiles() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let nm = try project(s)
    try engine.adopt(nm.path)
    // As a crash would leave it: package a's entries moved aside, not yet linked.
    let package = nm.appendingPathComponent("a")
    let trash = nm.appendingPathComponent(".stowaway-trash-test")
    let aside = trash.appendingPathComponent("0")
    try FileManager.default.createDirectory(at: aside, withIntermediateDirectories: true)
    try Data(package.path.utf8).write(
      to: trash.appendingPathComponent("0" + Engine.asideOwnerSuffix))
    for name in ["index.js", "package.json"] {
      let link = package.appendingPathComponent(name)
      let contents = try Data(contentsOf: link)
      try FileManager.default.removeItem(at: link)
      try contents.write(to: aside.appendingPathComponent(name))
    }

    engine.recover()

    XCTAssertEqual(
      try String(contentsOf: package.appendingPathComponent("index.js"), encoding: .utf8),
      "module.exports = require('b')")
    XCTAssertTrue(
      FileManager.default.fileExists(atPath: package.appendingPathComponent("package.json").path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: trash.path))
  }

  /// A stow that fails partway (a package can't be read) undoes the packages it had linked, as
  /// stowing a whole folder does.
  func testAFailedStowIsUndone() throws {
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let nm = try project(s)
    let locked = nm.appendingPathComponent("@scope/c/dist")
    XCTAssertEqual(chmod(locked.path, 0o300), 0)
    defer { chmod(locked.path, 0o700) }

    XCTAssertThrowsError(try engine.adopt(nm.path))
    XCTAssertTrue(engine.entries().isEmpty)
    for name in ["a/index.js", "a/package.json", "b/package.json"] {
      XCTAssertFalse(isSymlink(nm.appendingPathComponent(name).path), name)
    }
    XCTAssertEqual(
      try String(contentsOf: nm.appendingPathComponent("a/index.js"), encoding: .utf8),
      "module.exports = require('b')")
  }
}
