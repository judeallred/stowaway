import Foundation

// A sandboxed launch agent registered through SMAppService.agent. It records what it can do into
// its own container (~/Library/Containers/dev.stowaway.sandbox-probe.agent/Data/heartbeat.txt),
// then exits; launchd runs it again at the next login.

func run(_ path: String, _ args: [String]) -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: path)
  process.arguments = args
  let pipe = Pipe()
  process.standardOutput = pipe
  process.standardError = pipe
  do {
    try process.run()
  } catch {
    return "couldn't launch: \(error.localizedDescription)"
  }
  let data = pipe.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  let text = String(decoding: data, as: UTF8.self)
  return "exit \(process.terminationStatus), \(text.count) bytes"
}

let home = getpwuid(getuid()).flatMap { $0.pointee.pw_dir.map { String(cString: $0) } } ?? "?"
let lines = [
  "ran \(Date().formatted(.iso8601))",
  "container \(ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] ?? "none (not sandboxed)")",
  "hdiutil info: \(run("/usr/bin/hdiutil", ["info", "-plist"]))",
  "list ~/code: \((try? FileManager.default.contentsOfDirectory(atPath: home + "/code").count).map { "\($0) entries" } ?? "denied")",
]
try? lines.joined(separator: " | ").write(
  toFile: NSHomeDirectory() + "/heartbeat.txt", atomically: true, encoding: .utf8)
