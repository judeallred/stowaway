import AppKit
import Foundation
import ServiceManagement
import StowawayCore

/// One line in the library: a re-creatable folder, on the Mac or on the drive.
struct Row: Identifiable, Hashable {
  enum Place: Hashable {
    case mac
    case drive
    /// Offloaded, but the drive is away: tools are using a local folder meanwhile.
    case driveAway
  }

  var id: String { path }
  let kind: Kind
  let path: String
  let project: String?
  var place: Place
  /// Bytes on this Mac, once measured.
  var localBytes: Int64?
  /// Bytes on the drive (recorded when offloaded).
  var driveBytes: Int64 = 0
  var lastActivity: Date?
  /// Engine entries that make up this row (a Cargo `target/` is offloaded as several parts).
  var entryPaths: [String] = []

  var name: String {
    if let project { return URL(fileURLWithPath: project).lastPathComponent }
    return kind.label
  }

  var candidate: Candidate { Candidate(kind: kind, path: path, project: project) }
}

/// The app's state and actions. Engine work runs off the main actor; results come back here.
@MainActor @Observable
final class AppModel {
  let engine: Engine
  let store = Store()

  private(set) var rows: [Row] = []
  private(set) var scanning = false
  private(set) var busy: Set<String> = []
  private(set) var roots: [String] = []
  private(set) var drivePath: String?
  /// The offload location's name, known even while it's unplugged.
  private(set) var driveName: String?
  private(set) var driveConnected = false
  private(set) var driveFreeBytes: Int64?
  private(set) var offloadedBytes: Int64 = 0
  private(set) var loginItemEnabled = false
  var message: String?
  var showingSupport = false
  var showingOnboarding = false
  var started = false

  private var watchers: [any NSObjectProtocol] = []
  private var timer: Timer?
  private var scanTimer: Timer?
  /// Last measurement per folder, so a rescan only re-measures folders that changed.
  private var measured: [String: (bytes: Int64, activity: Date)] = [:]
  private var reconcileQueued = false

  /// Offload folders automatically once they've been unchanged this many minutes (0 = only by
  /// hand). Five minutes unless the user changes it: folders move to the drive soon after work
  /// in them stops.
  var autoOffloadMinutes: Int {
    get {
      UserDefaults.standard.object(forKey: "autoOffloadMinutes") == nil
        ? 5 : UserDefaults.standard.integer(forKey: "autoOffloadMinutes")
    }
    set {
      UserDefaults.standard.set(newValue, forKey: "autoOffloadMinutes")
      Task { await autoOffload() }
    }
  }

  /// Opens the library window (set by the menu bar label, which has SwiftUI's openWindow).
  var openLibrary: (() -> Void)?

  /// Whether first-run onboarding has been finished or skipped. Never shown again after that;
  /// everything it covers is reachable from the library and Settings.
  var didOnboard: Bool {
    get { UserDefaults.standard.bool(forKey: "didOnboard") }
    set { UserDefaults.standard.set(newValue, forKey: "didOnboard") }
  }

  init() {
    engine = Engine()
    engine.cleanupInBackground = true
  }

  func start() {
    engine.log = { [weak self] line in Task { @MainActor in self?.message = line } }
    store.start()
    refreshSettings()
    showingOnboarding = !didOnboard && roots.isEmpty
    if !roots.isEmpty { didOnboard = true }
    watchVolumes()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.queueReconcile() }
    }
    // Look again every couple of minutes, so automatic offloading keeps up with new folders.
    scanTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
      Task { @MainActor in await self?.scan() }
    }
    let engine = engine
    Task {
      // Finish anything a quit or crash interrupted before doing anything else.
      await Task.detached { engine.recover() }.value
      await store.waitUntilLoaded()
      queueReconcile()
      await scan()
    }
  }

  // MARK: Settings

  func refreshSettings() {
    roots = engine.rootPaths
    drivePath = engine.drivePath
    driveName = engine.driveName
    loginItemEnabled = SMAppService.mainApp.status == .enabled
    let engine = engine
    Task.detached {
      let store = engine.enterGrants()
      let free = store.flatMap {
        try? $0.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
          .volumeAvailableCapacityForImportantUsage
      }
      let bytes = engine.offloadedBytes
      await MainActor.run {
        self.driveConnected = store != nil
        self.driveFreeBytes = free
        self.offloadedBytes = bytes
      }
    }
  }

  func setLoginItem(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
    } catch {
      message = "Couldn't change Open at Login: \(error.localizedDescription)"
    }
    loginItemEnabled = SMAppService.mainApp.status == .enabled
  }

  // MARK: Grants

  /// Asks for a folder to scan. Returns false if the user cancelled or macOS gave back a
  /// different folder (the sandbox can remap some choices).
  @discardableResult
  func addRoot(startingAt directory: URL? = nil, message prompt: String? = nil) -> Bool {
    guard
      let url = choose(
        prompt ?? "Choose a folder that holds your projects, such as your code folder.",
        at: directory)
    else { return false }
    do {
      try engine.grant(url, as: .root)
    } catch {
      message = "Couldn't remember that folder: \(error.localizedDescription)"
      return false
    }
    refreshSettings()
    Task { await scan() }
    return true
  }

  /// Folders dropped on the app's icon: a drive becomes the offload location if none is set yet;
  /// anything else is added to the folders Stowaway looks in.
  func open(_ urls: [URL]) {
    for url in urls {
      let isVolume = (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
      do {
        if isVolume, url.path != "/", drivePath == nil {
          try engine.grant(url, as: .drive)
          message = "Offloading to \(url.lastPathComponent)."
        } else {
          try engine.grant(url, as: .root)
          message = "Added \(Format.path(url.path))."
        }
      } catch {
        message = "Couldn't add \(url.lastPathComponent): \(error.localizedDescription)"
      }
    }
    refreshSettings()
    Task { await scan() }
  }

  /// Creates the sample workspace in a folder the user picks and starts looking in it.
  func createSampleProject() {
    guard
      let parent = choose(
        "Choose where to put the sample. Stowaway creates a folder named “\(SampleProject.folderName)” there.",
        at: realHomeDirectory.appendingPathComponent("Documents"))
    else { return }
    do {
      let root = try SampleProject.create(in: parent)
      try engine.grant(root, as: .root)
      message =
        "Created a sample in \(Format.path(root.path)). Try offloading, bringing back or deleting it."
    } catch {
      message = "Couldn't create the sample: \(error.localizedDescription)"
    }
    refreshSettings()
    Task { await scan() }
  }

  func removeRoot(_ path: String) {
    engine.revokeRoot(path)
    refreshSettings()
    Task { await scan() }
  }

  func chooseDrive() {
    guard
      let url = choose(
        "Choose where offloaded folders go: an external drive, or a folder on one.",
        at: URL(fileURLWithPath: "/Volumes"))
    else { return }
    grantDrive(url)
  }

  private func grantDrive(_ url: URL) {
    do {
      try engine.grant(url, as: .drive)
    } catch {
      message = error.localizedDescription
    }
    refreshSettings()
    Task { await scan() }
  }

  private func choose(_ prompt: String, at directory: URL?) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.showsHiddenFiles = true
    panel.message = prompt
    panel.prompt = "Choose"
    panel.directoryURL = directory
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// Machine-wide caches that exist on this Mac but that Stowaway can't reach yet, with the folder
  /// to ask for (the one that contains them, so they can be swapped for a link). A folder inside
  /// another one on the list is left off: allowing the outer one covers it.
  var ungrantedCaches: [(kind: Kind, folder: URL)] {
    var result: [(kind: Kind, folder: URL)] = []
    for kind in Kind.allCases where kind.isGlobal {
      for rel in kind.defaultLocations {
        let path = realHomeDirectory.appendingPathComponent(rel)
        // The sandbox allows checking that a path exists, though not reading it.
        guard FileManager.default.fileExists(atPath: path.path), !isCovered(path.path) else {
          continue
        }
        let parent = path.deletingLastPathComponent()
        if !result.contains(where: { $0.folder == parent }) { result.append((kind, parent)) }
      }
    }
    return result.filter { candidate in
      !result.contains { other in
        other.folder != candidate.folder && candidate.folder.path.hasPrefix(other.folder.path + "/")
      }
    }
  }

  /// Folders where developers usually keep projects that exist here and aren't chosen yet.
  var suggestedProjectFolders: [URL] {
    ["code", "Developer", "Projects", "src", "dev", "GitHub", "repos", "workspace"]
      .map { realHomeDirectory.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) && !isCovered($0.path) }
  }

  /// External drives that are mounted now, for choosing the offload location in one click.
  /// Read-only volumes (installer disk images, for example) are left off.
  var externalVolumes: [URL] {
    let keys: [URLResourceKey] = [
      .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
      .volumeIsReadOnlyKey,
    ]
    let volumes =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
      ?? []
    return volumes.filter {
      let values = try? $0.resourceValues(forKeys: Set(keys))
      return values?.volumeIsRootFileSystem != true && values?.volumeIsInternal != true
        && values?.volumeIsBrowsable != false && values?.volumeIsReadOnly != true
    }
  }

  /// Asks for the home folder in one go, which covers projects and every cache. macOS can give
  /// back something narrower; then the per-folder buttons are the way.
  func allowHomeFolder() {
    guard
      let url = choose(
        "Click Choose to let Stowaway look through your home folder: your projects and every cache, in one step. It reads folder names and sizes, never your files' contents.",
        at: realHomeDirectory)
    else { return }
    guard url.standardizedFileURL.path == realHomeDirectory.standardizedFileURL.path else {
      message =
        "macOS gave Stowaway \(Format.path(url.path)) rather than your home folder. Allow each cache instead."
      return
    }
    do {
      try engine.grant(url, as: .root)
      message = "Stowaway can now see your home folder."
    } catch {
      message = "Couldn't remember your home folder: \(error.localizedDescription)"
    }
    refreshSettings()
    Task { await scan() }
  }

  /// Uses a mounted volume as the offload location (the panel opens on it; the user confirms).
  func chooseDrive(_ volume: URL) {
    guard
      let url = choose(
        "Click Choose to keep offloaded folders on \(volume.lastPathComponent).", at: volume)
    else { return }
    grantDrive(url)
  }

  /// Finishes onboarding. Open at Login is applied only here, from the toggle the user saw.
  func finishOnboarding(openAtLogin: Bool) {
    didOnboard = true
    showingOnboarding = false
    if openAtLogin && !loginItemEnabled { setLoginItem(true) }
  }

  /// Skips onboarding for good; the library and Settings cover everything it asks.
  func skipOnboarding() {
    didOnboard = true
    showingOnboarding = false
  }

  private func isCovered(_ path: String) -> Bool {
    roots.contains { path == $0 || path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
  }

  // MARK: Scanning

  func scan() async {
    guard !scanning else { return }
    scanning = true
    defer { scanning = false }
    let engine = engine
    let roots = engine.rootPaths
    let candidates = await Task.detached {
      engine.enterGrants()
      return Scanner().scan(roots: roots)
    }.value
    rows = merge(candidates: candidates, entries: engine.entries())
    refreshSettings()
    await measure()
    await autoOffload()
  }

  /// Combines what the scan found with what's offloaded. Offloaded parts (a Cargo `target/`'s
  /// build folders, DerivedData's intermediates) roll up into their container's row.
  private func merge(candidates: [Candidate], entries: [Entry]) -> [Row] {
    var rows: [String: Row] = [:]
    for c in candidates {
      rows[c.path] = Row(kind: c.kind, path: c.path, project: c.project, place: .mac)
    }
    for entry in entries {
      let container = Self.container(of: entry)
      var row =
        rows[container]
        ?? Row(
          kind: entry.kind ?? .node, path: container,
          project: Self.projectFolder(of: entry, container: container),
          place: .mac)
      row.place = entry.online ? .drive : .driveAway
      row.driveBytes += entry.bytes
      row.entryPaths.append(entry.local)
      rows[container] = row
    }
    return rows.values.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
  }

  /// The row an entry belongs to: the container recorded when it was offloaded.
  static func container(of entry: Entry) -> String {
    entry.container ?? entry.local
  }

  private static func projectFolder(of entry: Entry, container: String) -> String? {
    guard entry.kind?.isGlobal != true else { return nil }
    return URL(fileURLWithPath: container).deletingLastPathComponent().path
  }

  /// Measures sizes and recency in the background, a few folders at a time.
  private func measure() async {
    let pending = rows.map { ($0.path, $0.candidate, measured[$0.path]) }
    await withTaskGroup(of: (String, Int64, Date).self) { group in
      var iterator = pending.makeIterator()
      func next() -> Bool {
        guard let (path, candidate, previous) = iterator.next() else { return false }
        group.addTask {
          // Recency is cheap; size is only measured again if something changed.
          let activity = Measure.lastActivity(of: candidate)
          if let previous, previous.activity == activity { return (path, previous.bytes, activity) }
          return (path, Measure.allocatedSize(path), activity)
        }
        return true
      }
      for _ in 0..<4 where next() {}
      for await (path, bytes, date) in group {
        measured[path] = (bytes, date)
        if let i = rows.firstIndex(where: { $0.path == path }) {
          rows[i].localBytes = bytes
          rows[i].lastActivity = date
        }
        _ = next()
      }
    }
  }

  // MARK: Actions

  func offload(_ row: Row) async {
    guard drivePath != nil else {
      message = "Choose an offload location first."
      return
    }
    let paths: [String]
    if let parts = row.kind.parts(of: row.candidate.url) {
      paths = parts.map(\.path).filter { !row.entryPaths.contains($0) }
      if paths.isEmpty {
        message = "\(row.name) has no build folders to offload yet."
        return
      }
    } else {
      paths = [row.path]
    }
    await perform(row) { engine, limit in
      for path in paths {
        try engine.adopt(path, kind: row.kind, container: row.path, limit: limit)
      }
    }
  }

  func bringBack(_ row: Row) async {
    await perform(row) { engine, _ in
      for path in row.entryPaths { try engine.release(path) }
    }
  }

  func delete(_ row: Row) async {
    let roots = roots
    await perform(row) { engine, _ in
      if row.entryPaths.isEmpty {
        try Cleaner().delete(row.candidate, roots: roots, offloaded: engine.entries())
      } else {
        for path in row.entryPaths { try engine.discard(path) }
        // A Cargo target's remaining local part (built programs) goes too: delete means delete.
        // Through the cleaner, so it gets the same checks as any other delete.
        if row.kind == .cargoTarget, FileManager.default.fileExists(atPath: row.path) {
          try Cleaner().delete(row.candidate, roots: roots, offloaded: engine.entries())
        }
      }
    }
  }

  private func perform(_ row: Row, _ body: @escaping @Sendable (Engine, Int64?) throws -> Void)
    async
  {
    busy.insert(row.path)
    defer { busy.remove(row.path) }
    await store.waitUntilLoaded()
    let engine = engine
    let limit = store.offloadLimit
    let failure: (any Error)? = await Task.detached {
      do {
        try body(engine, limit)
        return nil
      } catch {
        return error
      }
    }.value
    if failure is OffloadLimitReached {
      showingSupport = true
    } else if let failure {
      message = failure.localizedDescription
    }
    await scan()
  }

  /// Offloads folders unchanged for `autoOffloadMinutes`, within the free limit. Skips folders
  /// a tool is using right now: a running Cargo build, DerivedData while Xcode runs, Gradle's
  /// caches while an IDE that runs Gradle does.
  private func autoOffload() async {
    let minutes = autoOffloadMinutes
    guard minutes > 0, driveConnected else { return }
    await store.waitUntilLoaded()
    let cutoff = Date().addingTimeInterval(-Double(minutes) * 60)
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let xcodeRunning = running.contains { $0.hasPrefix("com.apple.dt.Xcode") }
    let gradleIDERunning = running.contains {
      $0.hasPrefix("com.google.android.studio") || $0.hasPrefix("com.jetbrains.intellij")
    }
    for row in rows
    where row.place == .mac && row.localBytes != nil && (row.lastActivity ?? .now) < cutoff {
      if row.kind == .xcodeDerivedData && xcodeRunning { continue }
      if row.kind == .gradleHome && gradleIDERunning { continue }
      if Measure.isBusy(row.candidate) { continue }
      let engine = engine
      let limit = store.offloadLimit
      let paths = row.kind.parts(of: row.candidate.url)?.map(\.path) ?? [row.path]
      let container = row.path
      let stop = await Task.detached { () -> Bool in
        for path in paths {
          do {
            try engine.adopt(path, kind: row.kind, container: container, limit: limit)
          } catch is OffloadLimitReached {
            return true
          } catch {
            // Skipped (in use by git, overlapping…); the library shows it as still on the Mac.
          }
        }
        return false
      }.value
      if stop { break }
    }
  }

  // MARK: The drive coming and going

  private func watchVolumes() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      watchers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.queueReconcile() }
        })
    }
  }

  /// Reconciles soon, coalescing bursts (a drive and the images on it going at once).
  func queueReconcile() {
    guard !reconcileQueued else { return }
    reconcileQueued = true
    Task {
      try? await Task.sleep(for: .milliseconds(150))
      reconcileQueued = false
      let engine = engine
      await Task.detached { engine.reconcile() }.value
      let entries = engine.entries()
      for i in rows.indices where !rows[i].entryPaths.isEmpty {
        let online = entries.filter { rows[i].entryPaths.contains($0.local) }.allSatisfy(\.online)
        rows[i].place = online ? .drive : .driveAway
      }
      refreshSettings()
    }
  }

  // MARK: Totals

  var reclaimableBytes: Int64 {
    rows.filter { $0.place == .mac }.compactMap(\.localBytes).reduce(0, +)
  }
  var freeAllowanceLeft: Int64? {
    store.offloadLimit.map { max(0, $0 - offloadedBytes) }
  }
}

#if DEBUG
  extension AppModel {
    /// Snapshots (Snapshots.swift) only.
    var demoRows: [Row] {
      get { rows }
      set { rows = newValue }
    }

    func applyDemo(drive: String, roots: [String]) {
      self.roots = roots
      drivePath = drive
      driveConnected = true
      driveFreeBytes = 812_000_000_000
      offloadedBytes = rows.map(\.driveBytes).reduce(0, +)
    }
  }
#endif
