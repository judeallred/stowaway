import AppKit
import LiteEngine
import SwiftUI

// Command-line modes, for scripting (the sandbox applies however the app is started):
//   open -a StowawayLite.app <folders…> --args --grant   grant folders (under /Volumes = the drive)
//   StowawayLite --adopt <folder> | --release <folder> | --status | --reconcile
//   StowawayLite --watch <seconds>                         reconcile, then follow the drive
let arguments = CommandLine.arguments
let engine = Engine()
engine.log = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

func argument(after flag: String) -> String? {
  guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
  return arguments[i + 1]
}

func run(_ body: () throws -> Void) -> Never {
  do {
    try body()
    exit(0)
  } catch {
    engine.log("error: \(error.localizedDescription)")
    exit(1)
  }
}

if let path = argument(after: "--adopt") {
  run { try engine.adopt(path, allowTurbopack: arguments.contains("--allow-turbopack")) }
}
if let path = argument(after: "--release") { run { try engine.release(path) } }
// Diagnostics: times deleting a tree from inside the sandbox.
if let path = argument(after: "--bench-rm") {
  run {
    engine.enterGrants()
    let start = Date()
    try Copier.remove(URL(fileURLWithPath: path))
    print(String(format: "sandboxed Copier.remove %.2fs", Date().timeIntervalSince(start)))
  }
}
if arguments.contains("--reconcile") { run { engine.reconcile() } }
if arguments.contains("--status") {
  run {
    print("drive: \(engine.drivePath ?? "not chosen") (\(engine.enterGrants() == nil ? "away" : "connected"))")
    for e in engine.entries() {
      print("\(e.online ? "on drive" : "local   ")  \(e.mode == .packages ? "packages" : "folder  ")  \(e.local)")
    }
  }
}
if arguments.contains("--grant") || argument(after: "--watch") != nil {
  MainActor.assumeIsolated { Headless.run(seconds: Double(argument(after: "--watch") ?? "15") ?? 15) }
}
LiteApp.main()

/// Grants folders handed over by LaunchServices, and/or follows the drive for a while.
@MainActor enum Headless {
  final class Delegate: NSObject, NSApplicationDelegate {
    func application(_ application: NSApplication, open urls: [URL]) {
      for url in urls {
        do {
          try engine.grant(url)
          engine.log("granted \(url.path)")
        } catch {
          engine.log("couldn't grant \(url.path): \(error.localizedDescription)")
        }
      }
      if !arguments.contains("--watch") { exit(0) }
    }
  }

  static func run(seconds: Double) -> Never {
    let app = NSApplication.shared
    let delegate = Delegate()
    app.delegate = delegate
    if arguments.contains("--watch") {
      engine.cleanupInBackground = true
      engine.reconcile()
      DriveWatcher.start { engine.reconcile() }
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { exit(0) }
    app.run()
    exit(0)
  }
}

/// Calls back when volumes mount or unmount. A burst of events (a drive and the images on it
/// going at once) is coalesced into one callback.
@MainActor enum DriveWatcher {
  private static var pending = false

  static func start(_ changed: @escaping @MainActor () -> Void) {
    // Also check periodically, to re-offload packages an npm install brought back.
    Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in MainActor.assumeIsolated { changed() } }
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      center.addObserver(forName: name, object: nil, queue: .main) { note in
        let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path ?? "?"
        engine.log("\(name == NSWorkspace.didMountNotification ? "mounted" : "unmounted") \(volume)")
        MainActor.assumeIsolated {
          guard !pending else { return }
          pending = true
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            pending = false
            changed()
          }
        }
      }
    }
  }
}

struct LiteApp: App {
  @State private var model = LiteModel()

  var body: some Scene {
    WindowGroup("Stowaway Lite") {
      LiteView(model: model).frame(minWidth: 640, minHeight: 380)
        .onAppear { model.start() }
    }
  }
}

@MainActor @Observable
final class LiteModel {
  var entries: [Entry] = []
  var drive = "not chosen"
  var message = ""
  var busy = false

  func start() {
    engine.cleanupInBackground = true
    engine.log = { line in Task { @MainActor in self.message = line } }
    DriveWatcher.start { [weak self] in self?.refresh(reconcile: true) }
    refresh(reconcile: true)
  }

  func refresh(reconcile: Bool = false) {
    if reconcile { engine.reconcile() }
    entries = engine.entries()
    drive = "\(engine.drivePath ?? "not chosen")\(engine.enterGrants() == nil ? " (away)" : "")"
  }

  func pick(message: String, at directory: String? = nil) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.showsHiddenFiles = true
    panel.message = message
    if let directory { panel.directoryURL = URL(fileURLWithPath: directory) }
    return panel.runModal() == .OK ? panel.url : nil
  }

  func grant(_ prompt: String, at directory: String? = nil) {
    guard let url = pick(message: prompt, at: directory) else { return }
    do {
      try engine.grant(url)
      refresh()
    } catch {
      message = error.localizedDescription
    }
  }

  func adopt() {
    guard let url = pick(message: "Choose a folder to keep on the drive. Its parent folder must already be granted.") else { return }
    work { try engine.adopt(url.path) }
  }

  func release(_ entry: Entry) {
    work { try engine.release(entry.local) }
  }

  private func work(_ body: @escaping @Sendable () throws -> Void) {
    busy = true
    Task.detached {
      var failure: String?
      do { try body() } catch { failure = error.localizedDescription }
      await MainActor.run {
        if let failure { self.message = failure }
        self.busy = false
        self.refresh()
      }
    }
  }
}

struct LiteView: View {
  @Bindable var model: LiteModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack {
        Text("Drive: \(model.drive)")
        Spacer()
        Button("Choose Drive…") { model.grant("Choose your external drive.", at: "/Volumes") }
        Button("Grant Folder…") { model.grant("Grant a folder that contains things to offload, such as ~/code or ~/.cargo.") }
        Button("Offload Folder…") { model.adopt() }.disabled(model.busy)
      }
      Table(model.entries) {
        TableColumn("Folder") { Text($0.local).lineLimit(1).truncationMode(.middle) }
        TableColumn("Where") { Text($0.online ? "On drive" : "Local (drive away)") }.width(130)
        TableColumn("How") { Text($0.mode == .packages ? "Each package" : "Whole folder") }.width(100)
        TableColumn("") { entry in
          Button("Bring Back") { model.release(entry) }.disabled(model.busy)
        }.width(90)
      }
      Text(model.message).font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
    }
    .padding()
  }
}
