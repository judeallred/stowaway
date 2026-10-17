import Darwin
import Foundation
import LiteEngine

// Benchmark helper (not sandboxed). Replays the core engine's disk-image mechanism with the same
// hdiutil flags and staging flow as hdiutil.rs / engine.rs, using the same copier as Lite, so a
// comparison measures images-mounted-in-place against symlinks rather than two different copiers.
//
//   stowbench core-adopt <folder> <image-dir>   image on the drive, mounted at <folder>
//   stowbench core-detach <folder>              detach the image mounted at <folder>
//   stowbench core-attach <image> <folder>      attach an image at <folder> (reconnect)
//   stowbench wait-real-dir <path> <timeout>    ms until <path> is a real folder, not a symlink
//   stowbench wait-symlink <path> <timeout>     ms until <path> is a symlink again
//   stowbench wait-mounted <path> <timeout>     ms until a volume is mounted at <path>
//   stowbench wait-unmounted <path> <timeout>   ms until nothing is mounted at <path>

let args = Array(CommandLine.arguments.dropFirst())

func hdiutil(_ arguments: [String]) throws -> String {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
  process.arguments = arguments
  let out = Pipe()
  process.standardOutput = out
  process.standardError = FileHandle.standardError
  try process.run()
  let data = out.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  guard process.terminationStatus == 0 else { throw LiteError("hdiutil \(arguments.first ?? "") failed") }
  return String(decoding: data, as: UTF8.self)
}

func timed<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
  let start = Date()
  let result = try body()
  print(String(format: "  %-28@ %8.3fs", label as NSString, Date().timeIntervalSince(start)))
  return result
}

/// Mounts `image` at `path` exactly as hdiutil.rs does.
/// Retries: under bursts of attaches hdiutil sometimes fails with "no mountable file systems".
func attach(_ image: String, at path: String) throws {
  var attempt = 0
  while true {
    do {
      _ = try hdiutil(["attach", "-plist", "-nobrowse", "-noautoopen", "-owners", "on", "-mountpoint", path, image])
      break
    } catch {
      attempt += 1
      FileHandle.standardError.write(Data("attach attempt \(attempt) failed\n".utf8))
      if attempt == 3 { throw error }
      sleep(1)
    }
  }
  FileManager.default.createFile(atPath: path + "/.metadata_never_index", contents: nil)
}

func coreAdopt(folder: String, imageDir: String) throws {
  let fm = FileManager.default
  let start = Date()
  let name = URL(fileURLWithPath: folder).lastPathComponent
  let image = "\(imageDir)/\(name)-\(UUID().uuidString.prefix(8)).sparsebundle"
  try fm.createDirectory(atPath: imageDir, withIntermediateDirectories: true)
  // Core sizes each sparse image at the drive's capacity; it only takes what's written.
  let attrs = try fm.attributesOfFileSystem(forPath: imageDir)
  let capacityMB = max(((attrs[.systemSize] as? Int64) ?? 0) / 1_000_000, 100)
  try timed("hdiutil create") {
    _ = try hdiutil(["create", "-quiet", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-size", "\(capacityMB)m", "-volname", name, image])
  }
  let staging = NSTemporaryDirectory() + "stowbench-staging-\(UUID().uuidString.prefix(8))"
  try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
  try timed("attach at staging") { try attach(image, at: staging) }
  let stats = try timed("copy into image") { try Copier.copyContents(of: URL(fileURLWithPath: folder), into: URL(fileURLWithPath: staging)) }
  try timed("detach staging") { _ = try hdiutil(["detach", "-quiet", staging]) }
  try? fm.removeItem(atPath: staging)
  let old = folder + ".stowbench-old"
  try timed("swap and mount in place") {
    try fm.moveItem(atPath: folder, toPath: old)
    try fm.createDirectory(atPath: folder, withIntermediateDirectories: false)
    try attach(image, at: folder)
  }
  try timed("delete local copy") { try Copier.remove(URL(fileURLWithPath: old)) }
  print(String(format: "  %-28@ %8.3fs  (%@)", "TOTAL core adopt" as NSString, Date().timeIntervalSince(start), stats.description))
  print("image: \(image)")
}

func wait(_ path: String, timeout: Double, until done: (String) -> Bool) {
  let start = Date()
  while Date().timeIntervalSince(start) < timeout {
    if done(path) {
      print(String(format: "%.0f", Date().timeIntervalSince(start) * 1000))
      return
    }
    usleep(2000)
  }
  print("timeout")
}

func isSymlink(_ path: String) -> Bool {
  var st = stat()
  return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
}

func isRealDir(_ path: String) -> Bool {
  var st = stat()
  return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
}

func isMountPoint(_ path: String) -> Bool {
  var fs = statfs()
  guard statfs(path, &fs) == 0 else { return false }
  let on = withUnsafeBytes(of: &fs.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
  return on == path
}

do {
  switch args.first {
  case "rm" where args.count == 2:
    try timed("Copier.remove") { try Copier.remove(URL(fileURLWithPath: args[1])) }
  case "wait-mounted" where args.count == 3:
    wait(args[1], timeout: Double(args[2]) ?? 10) { isMountPoint($0) }
  case "wait-unmounted" where args.count == 3:
    wait(args[1], timeout: Double(args[2]) ?? 10) { !isMountPoint($0) }
  case "core-adopt" where args.count == 3:
    try coreAdopt(folder: args[1], imageDir: args[2])
  case "core-detach" where args.count == 2:
    _ = try hdiutil(["detach", "-quiet", "-force", args[1]])
  case "core-attach" where args.count == 3:
    try timed("core reattach") { try attach(args[1], at: args[2]) }
  case "wait-real-dir" where args.count == 3:
    wait(args[1], timeout: Double(args[2]) ?? 10) { isRealDir($0) }
  case "wait-symlink" where args.count == 3:
    wait(args[1], timeout: Double(args[2]) ?? 10) { isSymlink($0) }
  default:
    print("usage: see the comment at the top of Sources/stowbench/main.swift")
    exit(2)
  }
} catch {
  FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
  exit(1)
}
