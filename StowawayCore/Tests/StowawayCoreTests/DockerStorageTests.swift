import Foundation
import XCTest

@testable import StowawayCore

final class DockerStorageTests: XCTestCase {
  func testReportsAllocatedRatherThanMaximumSizeOnlyWithinGrants() throws {
    let s = try Scratch()
    let directory = try s.dir(DockerStorage.defaultDirectory)
    let disk = try s.file(DockerStorage.defaultDirectory + "/Docker.raw")
    let handle = try FileHandle(forWritingTo: disk)
    try handle.truncate(atOffset: 1 << 30)
    try handle.close()
    XCTAssertTrue(DockerStorage.disks(roots: [], home: s.root).isEmpty)
    let measured = try XCTUnwrap(DockerStorage.disks(roots: [s.root.path], home: s.root).first)
    XCTAssertEqual(measured.maximumBytes, 1 << 30)
    XCTAssertLessThan(measured.allocatedBytes, measured.maximumBytes)
    XCTAssertEqual(DockerStorage.disks(roots: [directory.path], home: s.root).count, 1)
    XCTAssertFalse(
      Scanner().caches(roots: [s.root.path], home: s.root).contains { $0.path == directory.path })
  }

  func testCustomDiskDirectoriesAndSymlinkedFiles() throws {
    let s = try Scratch()
    let disk = try s.file("external/docker/Docker.qcow2", "disk")
    let directory = disk.deletingLastPathComponent()
    XCTAssertEqual(
      DockerStorage.disks(roots: [directory.path], home: s.root).map(\.path), [disk.path])
    try s.dir("linked")
    try FileManager.default.createSymbolicLink(
      atPath: s.path("linked/Docker.raw"), withDestinationPath: disk.path)
    XCTAssertTrue(DockerStorage.disks(roots: [s.path("linked")], home: s.root).isEmpty)
  }

  func testVMDataCannotBeStowedOrCleanedAsACache() throws {
    let s = try Scratch()
    let (engine, code, _) = try makeEngine(s)
    try s.file("code/docker/Docker.raw", "persistent volume")
    let child = try s.dir("code/docker/cache")
    for path in [child.path, s.path("code/docker")] {
      XCTAssertThrowsError(try engine.adopt(path, kind: .pnpmCache))
      let candidate = Candidate(kind: .pnpmCache, path: path, project: nil)
      XCTAssertNotNil(Cleaner().refusal(candidate, roots: [code.path], offloaded: []))
      XCTAssertThrowsError(try Cleaner().delete(candidate, roots: [code.path], offloaded: []))
    }
    XCTAssertTrue(engine.entries().isEmpty)
    XCTAssertEqual(
      try String(contentsOfFile: s.path("code/docker/Docker.raw"), encoding: .utf8),
      "persistent volume")
  }
}
