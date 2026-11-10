import Foundation
import XCTest

@testable import StowawayCore

/// How long sweeps take on many files. Slow, so only with STOWAWAY_BENCHMARK=1.
final class SweepBenchmark: XCTestCase {
  func testWalkingManyFiles() throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["STOWAWAY_BENCHMARK"] == "1")
    let s = try Scratch()
    let (engine, _, _) = try makeEngine(s)
    let files = 30_000
    for project in ["a", "b"] {
      try s.file("code/\(project)/Cargo.toml")
      try s.file("code/\(project)/target/CACHEDIR.TAG")
      let deps = s.path("code/\(project)/target/debug/deps")
      try FileManager.default.createDirectory(atPath: deps, withIntermediateDirectories: true)
      for i in 0..<files {
        let dir = deps + "/d\(i / 500)"
        if i % 500 == 0 {
          try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        }
        try Data("file \(i)".utf8).write(to: URL(fileURLWithPath: dir + "/f\(i)"))
      }
      try engine.adopt(deps, kind: .cargoTarget, container: s.path("code/\(project)/target"))
    }
    var options = eager
    var start = Date()
    let first = engine.sweepSharedFiles(options)
    print(
      "BENCH first sweep (walk+hash+share) of \(2 * files) files: \(Date().timeIntervalSince(start))s, shared \(first.filesShared)"
    )
    start = Date()
    options.minimumAge = 3600
    let second = engine.sweepSharedFiles(options)
    print(
      "BENCH second sweep (walk only, nothing changed): \(Date().timeIntervalSince(start))s, seen \(second.filesSeen)"
    )
    XCTAssertEqual(first.filesShared, files)
  }
}
