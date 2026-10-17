import Foundation
import XCTest

@testable import StowawayCore

/// A scratch folder per test, removed afterwards.
final class Scratch {
  let root: URL

  init() throws {
    root = FileManager.default.temporaryDirectory
      .appendingPathComponent("stowaway-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
      .resolvingSymlinksInPath()
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
  }

  deinit {
    _ = try? Copier.remove(root)
  }

  @discardableResult
  func file(_ rel: String, _ contents: String = "") throws -> URL {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url)
    return url
  }

  @discardableResult
  func dir(_ rel: String) throws -> URL {
    let url = root.appendingPathComponent(rel)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }

  func path(_ rel: String) -> String { root.appendingPathComponent(rel).path }
}

/// An engine with its own defaults and state, a code root and a "drive" folder.
func makeEngine(_ scratch: Scratch) throws -> (Engine, code: URL, drive: URL) {
  let suite = "stowaway-tests-\(UUID().uuidString)"
  let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
  let engine = Engine(defaults: defaults, stateDirectory: try scratch.dir("state"))
  let code = try scratch.dir("code")
  let drive = try scratch.dir("drive")
  try engine.grant(code, as: .root)
  try engine.grant(drive, as: .drive)
  return (engine, code, drive)
}

@discardableResult
func shell(_ tool: String, _ args: [String], in dir: URL) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: tool)
  process.arguments = args
  process.currentDirectoryURL = dir
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  try process.run()
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let out = String(decoding: data, as: UTF8.self)
  guard process.terminationStatus == 0 else {
    throw StowawayError("\(tool) \(args) failed: \(out)")
  }
  return out
}
