import AppKit
import DiskArbitration
import Foundation

/// Terminal-driven experiments. Each runs inside the sandbox with the saved bookmarks in scope.
enum Experiments {
  /// `open -a SandboxProbe.app <folder>… --args --grant`: LaunchServices hands the folders to the
  /// app with sandbox extensions, exactly as dropping them on the Dock icon would. Saves each as a
  /// bookmark (paths under /Volumes become the drive), then quits.
  @MainActor static func grant() -> Never {
    final class Delegate: NSObject, NSApplicationDelegate {
      func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
          // Try the grant directly, before any bookmark round trip.
          let fm = FileManager.default
          let link = url.appendingPathComponent(".stowprobe-link")
          let listed = (try? fm.contentsOfDirectory(atPath: url.path).count).map { "\($0) entries" } ?? "denied"
          var linked = "ok"
          do { try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp") } catch { linked = "\(error.localizedDescription)" }
          try? fm.removeItem(at: link)
          Experiments.log("direct \(url.path): list \(listed), symlink \(linked)")
          let place: Place = url.path.hasPrefix("/Volumes/") ? .drive : .codeRoot
          do {
            try Bookmarks.save(url, as: place)
            Experiments.log("granted \(place.rawValue): \(url.path)")
          } catch {
            Experiments.log("couldn't bookmark \(url.path): \(error)")
          }
        }
        NSApp.terminate(nil)
      }
    }
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    DispatchQueue.main.asyncAfter(deadline: .now() + 15) {
      log("no folders were opened")
      exit(1)
    }
    app.run()
    exit(0)
  }

  /// `--panel <dir>`: shows a real open panel already inside `dir`; accepting it grants `dir`.
  /// Then lists and symlinks through the grant and saves it as the code-folder bookmark.
  @MainActor static func panel(_ dir: String) -> Never {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    app.activate(ignoringOtherApps: true)
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.showsHiddenFiles = true
    panel.directoryURL = URL(fileURLWithPath: dir)
    panel.prompt = "Grant"
    guard panel.runModal() == .OK, let url = panel.url else {
      log("panel cancelled")
      exit(1)
    }
    let fm = FileManager.default
    let probe = url.appendingPathComponent(".npm")
    let listed = (try? fm.contentsOfDirectory(atPath: probe.path).count).map { "\($0) entries" } ?? "denied"
    var linked = "ok"
    let link = url.appendingPathComponent("stowprobe-code/.stowprobe-link")
    do { try fm.createSymbolicLink(atPath: link.path, withDestinationPath: "/tmp") } catch { linked = error.localizedDescription }
    try? fm.removeItem(at: link)
    log("panel granted \(url.path): list .npm \(listed), symlink in stowprobe-code \(linked)")
    try? Bookmarks.save(url, as: .codeRoot)
    exit(0)
  }

  /// Resolves every saved bookmark, so this process (and the children it runs) can reach them.
  static func enterBookmarks() {
    for place in Place.allCases {
      switch Bookmarks.resolve(place) {
      case .success(let p): log("in scope: \(place.rawValue) = \(p.url.path)\(p.stale ? " (stale)" : "")")
      case .failure(let error): log("bookmark \(place.rawValue) failed: \(error.localizedDescription)")
      case nil: break
      }
    }
  }

  /// `--da-mount <bsd> <path>`: mounts a volume at a path through DiskArbitration.
  static func daMount(bsd: String, path: String) -> Int32 {
    run(bsd: bsd) { disk, callback, context in
      DADiskMount(disk, URL(fileURLWithPath: path) as CFURL, DADiskMountOptions(kDADiskMountOptionDefault), callback, context)
    }
  }

  /// `--da-unmount <bsd>`: unmounts a volume through DiskArbitration (no force, so it fails if
  /// anything has files open).
  static func daUnmount(bsd: String) -> Int32 {
    run(bsd: bsd) { disk, callback, context in
      DADiskUnmount(disk, DADiskUnmountOptions(kDADiskUnmountOptionDefault), callback, context)
    }
  }

  private static func run(
    bsd: String,
    _ body: (DADisk, DADiskMountCallback, UnsafeMutableRawPointer) -> Void
  ) -> Int32 {
    guard let session = DASessionCreate(kCFAllocatorDefault) else { return fail("no DA session") }
    DASessionSetDispatchQueue(session, DispatchQueue(label: "da"))
    guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, bsd.replacingOccurrences(of: "/dev/", with: "")) else {
      return fail("no disk \(bsd)")
    }
    final class Box: @unchecked Sendable {
      let done = DispatchSemaphore(value: 0)
      var error: String?
    }
    let box = Box()
    body(disk, { _, dissenter, context in
      let box = Unmanaged<Box>.fromOpaque(context!).takeRetainedValue()
      if let dissenter {
        let text = DADissenterGetStatusString(dissenter).map { $0 as String } ?? ""
        box.error = String(format: "dissented: 0x%08x %@", DADissenterGetStatus(dissenter), text)
      }
      box.done.signal()
    }, Unmanaged.passRetained(box).toOpaque())
    guard box.done.wait(timeout: .now() + 30) == .success else { return fail("timed out") }
    if let error = box.error { return fail(error) }
    log("ok")
    return 0
  }

  private static func fail(_ message: String) -> Int32 {
    log(message)
    return 1
  }

  static func log(_ message: String) {
    FileHandle.standardError.write(Data((message + "\n").utf8))
  }
}
