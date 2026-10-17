import Foundation

/// The result of running a command-line tool from inside the sandbox.
struct ShellResult: Sendable {
  var status: Int32 = -1
  var out = ""
  var err = ""
  /// Set when the tool couldn't be started at all.
  var launchError: String?
  var timedOut = false

  var ok: Bool { launchError == nil && !timedOut && status == 0 }

  /// One-line summary for a probe's detail column.
  var summary: String {
    if let launchError { return "couldn't launch: \(launchError)" }
    if timedOut { return "timed out" }
    let text = (status == 0 ? out : (err.isEmpty ? out : err))
      .trimmingCharacters(in: .whitespacesAndNewlines)
    let firstLines = text.split(separator: "\n").prefix(3).joined(separator: " ⏎ ")
    return "exit \(status): \(firstLines.prefix(300))"
  }
}

/// Runs `path` with `args`. Children of a sandboxed process inherit its sandbox, so this tells us
/// what Stowaway's `cmd::run` calls would see in a Mac App Store build.
func sh(_ path: String, _ args: [String], timeout: TimeInterval = 60) -> ShellResult {
  var result = ShellResult()
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = args
  // Temp files rather than pipes, so large outputs (lsof) can't fill a pipe and deadlock.
  let tmp = FileManager.default.temporaryDirectory
  let outURL = tmp.appendingPathComponent("sh-\(UUID().uuidString).out")
  let errURL = tmp.appendingPathComponent("sh-\(UUID().uuidString).err")
  FileManager.default.createFile(atPath: outURL.path, contents: nil)
  FileManager.default.createFile(atPath: errURL.path, contents: nil)
  defer {
    try? FileManager.default.removeItem(at: outURL)
    try? FileManager.default.removeItem(at: errURL)
  }
  guard let outHandle = try? FileHandle(forWritingTo: outURL),
    let errHandle = try? FileHandle(forWritingTo: errURL)
  else {
    result.launchError = "couldn't create temp files in \(tmp.path)"
    return result
  }
  process.standardOutput = outHandle
  process.standardError = errHandle
  process.standardInput = FileHandle.nullDevice
  let done = DispatchSemaphore(value: 0)
  process.terminationHandler = { _ in done.signal() }
  do {
    try process.run()
  } catch {
    result.launchError = error.localizedDescription
    return result
  }
  if done.wait(timeout: .now() + timeout) == .timedOut {
    process.terminate()
    result.timedOut = true
    done.wait()
  }
  try? outHandle.close()
  try? errHandle.close()
  result.status = process.terminationStatus
  result.out = (try? String(contentsOf: outURL, encoding: .utf8)) ?? ""
  result.err = (try? String(contentsOf: errURL, encoding: .utf8)) ?? ""
  return result
}

func parsePlist(_ text: String) -> [String: Any]? {
  // hdiutil sometimes prints progress lines before the plist.
  guard let start = text.range(of: "<?xml") else { return nil }
  let data = Data(text[start.lowerBound...].utf8)
  return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
}
