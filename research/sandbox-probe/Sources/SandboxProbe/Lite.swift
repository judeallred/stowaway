import AppKit
import Foundation

/// A sandbox-only Stowaway: no disk images, no mounts. Each adopted folder moves to the drive and
/// is replaced by a symlink. When the drive goes away the symlink becomes an empty local folder so
/// tools keep working; when it comes back, anything built locally is merged onto the drive and the
/// symlink returns. Suits tools that accept a symlinked folder (global caches, not node_modules).
enum Lite {
  struct Entry: Codable {
    var local: String
    var remote: String
    var online: Bool
  }

  private static var stateURL: URL {
    URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("lite-state.json")
  }

  static func load() -> [Entry] {
    (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: stateURL))) ?? []
  }

  static func save(_ entries: [Entry]) {
    try? JSONEncoder().encode(entries).write(to: stateURL)
  }

  /// `--lite-adopt <folder>`: moves the folder onto the drive and leaves a symlink.
  static func adopt(_ path: String) -> Int32 {
    guard case .success(let drive)? = Bookmarks.resolve(.drive) else { return fail("no drive bookmark") }
    let fm = FileManager.default
    let local = URL(fileURLWithPath: path)
    let remote = drive.url.appendingPathComponent("Stowaway Lite/\(local.lastPathComponent)-\(UUID().uuidString.prefix(6))")
    let start = Date()
    do {
      try fm.createDirectory(at: remote.deletingLastPathComponent(), withIntermediateDirectories: true)
      try fm.moveItem(at: local, to: remote)
      try fm.createSymbolicLink(at: local, withDestinationURL: remote)
    } catch {
      return fail("adopt failed: \(error.localizedDescription)")
    }
    var entries = load()
    entries.append(Entry(local: local.path, remote: remote.path, online: true))
    save(entries)
    Experiments.log(String(format: "adopted %@ → %@ in %.2fs", local.path, remote.path, Date().timeIntervalSince(start)))
    return 0
  }

  /// `--lite-watch <seconds>`: reacts to the drive going and coming for that long.
  @MainActor static func watch(seconds: Double) -> Never {
    let center = NSWorkspace.shared.notificationCenter
    center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { note in
      let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path ?? "?"
      Experiments.log("unmounted \(volume)")
      MainActor.assumeIsolated { goOffline(volume: volume) }
    }
    center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { note in
      let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path ?? "?"
      Experiments.log("mounted \(volume)")
      MainActor.assumeIsolated { goOnline(volume: volume) }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    Experiments.log("watching for \(Int(seconds))s")
    RunLoop.main.run()
    exit(0)
  }

  /// Swaps each symlink into the vanished volume for an empty local folder.
  @MainActor private static func goOffline(volume: String) {
    let fm = FileManager.default
    var entries = load()
    for i in entries.indices where entries[i].online && entries[i].remote.hasPrefix(volume + "/") {
      do {
        try fm.removeItem(atPath: entries[i].local)
        try fm.createDirectory(atPath: entries[i].local, withIntermediateDirectories: false)
        entries[i].online = false
        Experiments.log("offline: \(entries[i].local) is now a local folder")
      } catch {
        Experiments.log("couldn't go offline for \(entries[i].local): \(error.localizedDescription)")
      }
    }
    save(entries)
  }

  /// Merges what was built locally onto the drive, then restores the symlink.
  @MainActor private static func goOnline(volume: String) {
    // The drive's bookmark has to be resolved again after it remounts.
    guard case .success(let drive)? = Bookmarks.resolve(.drive) else {
      Experiments.log("drive bookmark didn't resolve after remount")
      return
    }
    Experiments.log("drive bookmark resolved again: \(drive.url.path)\(drive.stale ? " (stale)" : "")")
    let fm = FileManager.default
    var entries = load()
    for i in entries.indices where !entries[i].online && entries[i].remote.hasPrefix(volume + "/") {
      let local = URL(fileURLWithPath: entries[i].local)
      let remote = URL(fileURLWithPath: entries[i].remote)
      do {
        var merged = 0
        for item in try fm.contentsOfDirectory(at: local, includingPropertiesForKeys: nil) {
          let target = remote.appendingPathComponent(item.lastPathComponent)
          if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
          try fm.moveItem(at: item, to: target)
          merged += 1
        }
        try fm.removeItem(at: local)
        try fm.createSymbolicLink(at: local, withDestinationURL: remote)
        entries[i].online = true
        Experiments.log("online: \(local.path) → drive again, merged \(merged) local items")
      } catch {
        Experiments.log("couldn't go online for \(local.path): \(error.localizedDescription)")
      }
    }
    save(entries)
  }

  private static func fail(_ message: String) -> Int32 {
    Experiments.log(message)
    return 1
  }
}
