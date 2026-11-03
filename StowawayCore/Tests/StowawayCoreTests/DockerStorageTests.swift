import Foundation
import XCTest

@testable import StowawayCore

final class DockerStorageTests: XCTestCase {
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
