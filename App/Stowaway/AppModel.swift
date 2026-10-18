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
  /// Folders waiting their turn in a Stow batch that's running.
  private(set) var queued: Set<String> = []
  /// Folders Stowaway couldn't stow (a pnpm project, say), with their last-changed date then.
  /// Automatic stowing leaves them alone until they change.
  private var refused: [String: Date?] = [:]
  private(set) var roots: [String] = []
  private(set) var drivePath: String?
  /// The offload location's name, known even while it's unplugged.
  private(set) var driveName: String?
  private(set) var driveConnected = false
  private(set) var driveFreeBytes: Int64?
  private(set) var driveTotalBytes: Int64?
  /// The drive's format, such as "APFS" or "ExFAT".
  private(set) var driveFormat: String?
  /// The last speed test of the offload location (kept until the location changes).
  private(set) var driveSpeed: DriveSpeed? = {
    UserDefaults.standard.data(forKey: "driveSpeed").flatMap {
      try? JSONDecoder().decode(DriveSpeed.self, from: $0)
    }
  }()
  private(set) var testingSpeed = false
  private(set) var offloadedBytes: Int64 = 0
  private(set) var loginItemEnabled = false
  /// What Stowaway is doing right now ("Scanning…", what's moving), for the status line.
  private(set) var activity: String?
  /// The kind of work `activity` describes, for the menu bar icon's badge.
  private(set) var operation: Operation?

  enum Operation { case scanning, stowing, bringingBack, deleting, testing }
  /// A problem with something the user just did. Cleared after a few seconds: the status line
  /// is for what's happening now, not a log.
  var message: String? {
    didSet {
      guard let message else { return }
      Task {
        try? await Task.sleep(for: .seconds(8))
        if self.message == message { self.message = nil }
      }
    }
  }
  var showingSupport = false
  var showingOnboarding = false
  var started = false

  private var watchers: [any NSObjectProtocol] = []
  private var timer: Timer?
  private var scanTimer: Timer?
  /// Last measurement per folder, so a rescan only re-measures folders that changed.
  private var measured: [String: (bytes: Int64, activity: Date)] = [:]
  private var reconcileQueued = false
  /// When stowed folders were last re-measured on the drive (see `recountStowed`).
  private var lastRecount = Date.distantPast
  private var detectedProjectFolders: [ProjectFinder.Suggestion] = []

  /// Offload folders automatically once they've been unchanged this many minutes (0 = only by
  /// hand, `immediately` = as soon as a scan finds them). Five minutes unless the user changes
  /// it: folders move to the drive soon after work in them stops.
  /// Stored (not read through from UserDefaults) so SwiftUI sees changes.
  var autoOffloadMinutes: Int =
    UserDefaults.standard.object(forKey: "autoOffloadMinutes") == nil
    ? 5 : UserDefaults.standard.integer(forKey: "autoOffloadMinutes")
  {
    didSet {
      UserDefaults.standard.set(autoOffloadMinutes, forKey: "autoOffloadMinutes")
      Task { await autoOffload() }
    }
  }

  /// `autoOffloadMinutes` for offloading as soon as a scan finds a folder. Even then a folder
  /// must have been quiet for 30 seconds, so Stowaway never copies one mid-write.
  static let immediately = -1

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
    store.start()
    refreshSettings()
    let cache = ScanCache.load()
    for folder in cache.folders { measured[folder.path] = (folder.bytes, folder.activity) }
    rows = merge(candidates: cache.candidates, entries: engine.entries())
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
    driveName = engine.driveName
    loginItemEnabled = SMAppService.mainApp.status == .enabled
    let engine = engine
    // Everything that touches the drive runs off the main thread: a drive busy with a big copy
    // can take seconds to answer.
    Task.detached {
      let drivePath = engine.drivePath
      let store = engine.enterGrants()
      let values = store.flatMap {
        try? $0.resourceValues(forKeys: [
          .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
          .volumeLocalizedFormatDescriptionKey,
        ])
      }
      let free = values?.volumeAvailableCapacityForImportantUsage
      let total = values?.volumeTotalCapacity.map(Int64.init)
      let format = values?.volumeLocalizedFormatDescription
      let bytes = engine.offloadedBytes
      await MainActor.run {
        self.drivePath = drivePath
        self.driveConnected = store != nil
        self.driveFreeBytes = free
        self.driveTotalBytes = total
        self.driveFormat = format
        self.offloadedBytes = bytes
      }
    }
  }

  /// Measures the offload location's speed (a few seconds; writes and removes a 256 MB file).
  func testDriveSpeed() async {
    guard !testingSpeed else { return }
    testingSpeed = true
    activity = "Testing the drive's speed…"
    operation = .testing
    defer {
      testingSpeed = false
      activity = nil
      operation = nil
    }
    let engine = engine
    let result = await Task.detached { () -> Result<DriveSpeed, Error>? in
      guard let store = engine.enterGrants() else { return nil }
      return Result { try DriveSpeed.measure(in: store) }
    }.value
    switch result {
    case .success(let speed):
      driveSpeed = speed
      UserDefaults.standard.set(try? JSONEncoder().encode(speed), forKey: "driveSpeed")
    case .failure(let error):
      message = "Couldn't test the drive: \(error.localizedDescription)"
    case nil:
      message = "Connect your drive to test it."
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
    grant(url, as: .root, failure: "Couldn't remember that folder")
    return true
  }

  /// Saves a grant off the main thread (making a bookmark can stall while a drive is busy), then
  /// refreshes and rescans. `then` runs once the grant is saved.
  private func grant(
    _ url: URL, as role: Engine.GrantRole, failure: String? = nil,
    then: (@MainActor () -> Void)? = nil
  ) {
    let engine = engine
    Task {
      do {
        try await Task.detached { try engine.grant(url, as: role) }.value
        then?()
      } catch {
        message =
          failure.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription
      }
      refreshSettings()
      await scan()
    }
  }

  /// Folders dropped on the app's icon: a drive becomes the offload location if none is set yet;
  /// anything else is added to the folders Stowaway looks in.
  func open(_ urls: [URL]) {
    for url in urls {
      let isVolume = (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
      let role: Engine.GrantRole = isVolume && url.path != "/" && driveName == nil ? .drive : .root
      grant(url, as: role, failure: "Couldn't add \(url.lastPathComponent)")
    }
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
        "Created a sample in \(Format.path(root.path)). Try stowing, bringing back or deleting it."
    } catch {
      message = "Couldn't create the sample: \(error.localizedDescription)"
    }
    refreshSettings()
    Task { await scan() }
  }

  /// The chosen folders with any chosen inside another folded under it: the outer one already
  /// covers them. (Their grants are kept, so removing the outer one leaves them working.)
  var rootGroups: [(root: String, nested: [String])] {
    func inside(_ path: String, _ other: String) -> Bool {
      path != other && path.hasPrefix(other.hasSuffix("/") ? other : other + "/")
    }
    let sorted = roots.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    return sorted.filter { root in !sorted.contains { inside(root, $0) } }
      .map { top in (top, sorted.filter { inside($0, top) }) }
  }

  /// Stops looking in a folder, and in any chosen folders inside it.
  func removeRoot(_ path: String) {
    let nested = rootGroups.first { $0.root == path }?.nested ?? []
    for root in [path] + nested { engine.revokeRoot(root) }
    refreshSettings()
    Task { await scan() }
  }

  func chooseDrive() {
    guard
      let url = choose(
        "Choose where stowed folders go: an external drive, or a folder on one.",
        at: URL(fileURLWithPath: "/Volumes"))
    else { return }
    grantDrive(url)
  }

  /// Stops using the drive, after asking how: with folders stowed on it, bring them all back or
  /// delete them; with the drive away, forget it and leave its copies there.
  func stopUsingDrive() {
    guard let name = driveName else { return }
    let stowed = rows.filter { !$0.entryPaths.isEmpty }
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = "Stop using \(name)?"
    NSApp.activate()
    if stowed.isEmpty {
      alert.informativeText = "Nothing is stowed on it. You can choose a drive again any time."
      alert.addButton(withTitle: "Stop Using")
      alert.addButton(withTitle: "Cancel")
      if alert.runModal() == .alertFirstButtonReturn { forgetDrive() }
      return
    }
    let bytes = Format.bytes(stowed.map(\.driveBytes).reduce(0, +))
    let folders = "\(stowed.count) folder\(stowed.count == 1 ? "" : "s") (\(bytes))"
    if driveConnected {
      alert.informativeText =
        "\(folders) are stowed on it. Bring them back to this Mac, which needs room for them, or delete them: your tools re-create them when they need them."
      alert.addButton(withTitle: "Bring Everything Back")
      alert.addButton(withTitle: "Delete Stowed Folders").hasDestructiveAction = true
      alert.addButton(withTitle: "Cancel")
      switch alert.runModal() {
      case .alertFirstButtonReturn:
        Task {
          await bringBack(stowed)
          forgetDriveIfEmpty(name)
        }
      case .alertSecondButtonReturn:
        Task {
          await delete(stowed)
          forgetDriveIfEmpty(name)
        }
      default: break
      }
    } else {
      alert.informativeText =
        "\(folders) are stowed on it, and it isn't connected. Connect it to bring them back. Or forget it anyway: each becomes a local folder your tools rebuild into, and the copies stay on the drive, in its Stowaway.noindex folder."
      alert.addButton(withTitle: "Forget Anyway").hasDestructiveAction = true
      alert.addButton(withTitle: "Cancel")
      guard alert.runModal() == .alertFirstButtonReturn else { return }
      let engine = engine
      Task {
        do {
          try await Task.detached { try engine.abandonDrive() }.value
        } catch {
          message = error.localizedDescription
        }
        driveForgotten()
      }
    }
  }

  private func forgetDriveIfEmpty(_ name: String) {
    guard engine.entries().isEmpty else {
      message = "Some folders couldn't be brought back or deleted, so Stowaway still uses \(name)."
      return
    }
    forgetDrive()
  }

  private func forgetDrive() {
    do {
      try engine.forgetDrive()
    } catch {
      message = error.localizedDescription
    }
    driveForgotten()
  }

  private func driveForgotten() {
    driveSpeed = nil
    UserDefaults.standard.removeObject(forKey: "driveSpeed")
    refreshSettings()
    Task { await scan() }
  }

  private func grantDrive(_ url: URL) {
    grant(url, as: .drive) { [weak self] in
      // A new location: test its speed, so Settings can say what it's good for.
      self?.driveSpeed = nil
      UserDefaults.standard.removeObject(forKey: "driveSpeed")
      Task { await self?.testDriveSpeed() }
    }
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

  /// Where the user seems to keep projects (found with Spotlight), minus folders already
  /// chosen. Falls back to the usual names when Spotlight finds nothing.
  var suggestedProjectFolders: [ProjectFinder.Suggestion] {
    let found = detectedProjectFolders.filter { !isCovered($0.folder.path) }
    if !detectedProjectFolders.isEmpty { return found }
    return ["code", "Developer", "Projects", "src", "dev", "GitHub", "repos", "workspace"]
      .map { realHomeDirectory.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) && !isCovered($0.path) }
      .map { ProjectFinder.Suggestion(folder: $0, projects: 0) }
  }

  /// How many folders Settings → Suggested Folders would offer.
  var suggestionCount: Int {
    suggestedProjectFolders.filter { $0.projects > 0 }.count + ungrantedCaches.count
  }

  /// Fills `detectedProjectFolders` from Spotlight. Called when onboarding shows.
  func detectProjectFolders() async {
    detectedProjectFolders = await ProjectFinder.suggestions()
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
    grant(url, as: .root, failure: "Couldn't remember your home folder")
  }

  /// Uses a mounted volume as the offload location (the panel opens on it; the user confirms).
  func chooseDrive(_ volume: URL) {
    guard
      let url = choose(
        "Click Choose to keep stowed folders on \(volume.lastPathComponent).", at: volume)
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
    if activity == nil {
      activity = "Scanning your folders…"
      operation = .scanning
    }
    defer {
      scanning = false
      if operation == .scanning {
        activity = nil
        operation = nil
      }
    }
    let engine = engine
    let roots = engine.rootPaths
    // Caches first: they're found instantly, while walking the folders can take a while.
    let caches = await Task.detached {
      engine.enterGrants()
      return Scanner().caches(roots: roots)
    }.value
    let known = Set(rows.map(\.path))
    let newCaches = caches.filter { !known.contains($0.path) }
    if !newCaches.isEmpty {
      rows = merge(
        candidates: rows.filter { $0.entryPaths.isEmpty }.map(\.candidate) + newCaches,
        entries: engine.entries())
    }
    let candidates = await Task.detached {
      engine.enterGrants()
      return Scanner().scan(roots: roots)
    }.value
    rows = merge(candidates: candidates, entries: engine.entries())
    refreshSettings()
    await measure()
    saveCache(candidates)
    await recountStowed()
    await autoOffload()
  }

  /// Combines what the scan found with what's offloaded. Offloaded parts (a Cargo `target/`'s
  /// build folders, DerivedData's intermediates) roll up into their container's row.
  private func merge(candidates: [Candidate], entries: [Entry]) -> [Row] {
    var rows: [String: Row] = [:]
    for c in candidates {
      var row = Row(kind: c.kind, path: c.path, project: c.project, place: .mac)
      // Last known size and recency until this scan measures again, so totals are corrected
      // rather than recounted from zero.
      if let known = measured[c.path] {
        row.localBytes = known.bytes
        row.lastActivity = known.activity
      }
      rows[c.path] = row
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

  /// Every 10 minutes at most, re-measures stowed folders on the drive, so the stowed total keeps
  /// up with tools that write into them.
  private func recountStowed() async {
    guard driveConnected, Date.now.timeIntervalSince(lastRecount) > 600 else { return }
    lastRecount = .now
    let engine = engine
    await Task.detached { engine.recountStowed() }.value
    rows = merge(candidates: rows.map(\.candidate), entries: engine.entries())
    refreshSettings()
  }

  private func saveCache(_ candidates: [Candidate]) {
    let folders = candidates.compactMap { c in
      measured[c.path].map {
        ScanCache.Folder(
          path: c.path, kind: c.kind.rawValue, project: c.project, bytes: $0.bytes,
          activity: $0.activity)
      }
    }
    // Forget folders that are gone, so the cache doesn't grow forever.
    let current = Set(candidates.map(\.path))
    measured = measured.filter { current.contains($0.key) }
    ScanCache(folders: folders).save()
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

  func offload(_ row: Row) async { await offload([row]) }
  func bringBack(_ row: Row) async { await bringBack([row]) }
  func delete(_ row: Row) async { await delete([row]) }

  /// Offloads each folder in turn. With several, folders Stowaway can't offload (a pnpm
  /// project, say) are skipped and counted in the summary rather than stopping the rest.
  func offload(_ rows: [Row]) async {
    guard drivePath != nil else {
      message = "Choose where to stow first."
      return
    }
    await bulk(rows, doing: "Stowing") { row, engine, limit in
      let paths: [String]
      if let parts = row.kind.parts(of: row.candidate.url) {
        paths = parts.map(\.path).filter { !row.entryPaths.contains($0) }
        if paths.isEmpty { throw NothingToOffload(name: row.name) }
      } else {
        paths = [row.path]
      }
      for path in paths {
        try engine.adopt(path, kind: row.kind, container: row.path, limit: limit)
      }
    }
  }

  func bringBack(_ rows: [Row]) async {
    await bulk(rows, doing: "Bringing back") { row, engine, _ in
      for path in row.entryPaths { try engine.release(path) }
    }
  }

  func delete(_ rows: [Row]) async {
    let roots = roots
    await bulk(rows, doing: "Deleting") { row, engine, _ in
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

  /// "Stowing node_modules in alchemist (2.8 GB) · 3 of 12…"
  private static func describe(_ verb: String, _ row: Row, index: Int, of count: Int) -> String {
    let what = row.project == nil ? row.kind.label : "\(row.kind.label) in \(row.name)"
    let bytes = row.place == .mac ? row.localBytes : row.driveBytes
    var text = "\(verb) \(what)"
    if let bytes, bytes > 0 { text += " (\(Format.bytes(bytes)))" }
    if count > 1 { text += " · \(index + 1) of \(count)" }
    return text + "…"
  }

  private struct NothingToOffload: LocalizedError {
    let name: String
    var errorDescription: String? { "\(name) has no build folders to stow yet." }
  }

  /// Runs `body` for each row, one at a time, then rescans once. One row's failure is shown as
  /// is; with several, failures are skipped and summarized. Reaching the free limit stops the
  /// run and offers the upgrade.
  private func bulk(
    _ rows: [Row], doing: String,
    _ body: @escaping @Sendable (Row, Engine, Int64?) throws -> Void
  ) async {
    guard !rows.isEmpty else { return }
    await store.waitUntilLoaded()
    let engine = engine
    var failures: [(Row, any Error)] = []
    let stowing = doing == "Stowing"
    let op: Operation = stowing ? .stowing : doing == "Deleting" ? .deleting : .bringingBack
    if stowing { queued.formUnion(rows.map(\.path)) }
    defer { queued.subtract(rows.map(\.path)) }
    for (i, row) in rows.enumerated() {
      activity = Self.describe(doing, row, index: i, of: rows.count)
      operation = op
      queued.remove(row.path)
      busy.insert(row.path)
      let limit = store.offloadLimit
      let failure: (any Error)? = await Task.detached {
        do {
          try body(row, engine, limit)
          return nil
        } catch {
          return error
        }
      }.value
      busy.remove(row.path)
      if failure is OffloadLimitReached {
        showingSupport = true
        break
      }
      if let failure {
        failures.append((row, failure))
        if stowing { refused[row.path] = row.lastActivity }
      }
    }
    activity = nil
    operation = nil
    // One folder: say why it couldn't be done. Several: skip what can't be, quietly.
    if rows.count == 1, let (_, error) = failures.first {
      message = error.localizedDescription
    }
    await scan()
  }

  /// Offloads folders unchanged for `autoOffloadMinutes`, within the free limit. Skips folders
  /// a tool is using right now: a running Cargo build, DerivedData while Xcode runs, Gradle's
  /// caches while an IDE that runs Gradle does.
  private enum AutoOutcome: Sendable { case stowed, refused, limit }

  /// Bytes on this Mac still to be stowed: every re-creatable folder here that Stowaway can stow
  /// (folders it couldn't, such as a pnpm project, are left out until they change). Stowed plus
  /// pending is `eligibleBytes`.
  var pendingBytes: Int64 {
    rows
      .filter { row in
        guard row.place == .mac else { return false }
        if let at = refused[row.path], at == row.lastActivity { return false }
        return true
      }
      .compactMap(\.localBytes).reduce(0, +)
  }

  /// All the re-creatable data Stowaway manages: what's stowed plus what's pending.
  var eligibleBytes: Int64 { offloadedBytes + pendingBytes }

  private func autoOffload() async {
    let minutes = autoOffloadMinutes
    guard minutes != 0, driveConnected else { return }
    await store.waitUntilLoaded()
    let cutoff = Date().addingTimeInterval(
      minutes == Self.immediately ? -30 : -Double(minutes) * 60)
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let xcodeRunning = running.contains { $0.hasPrefix("com.apple.dt.Xcode") }
    let gradleIDERunning = running.contains {
      $0.hasPrefix("com.google.android.studio") || $0.hasPrefix("com.jetbrains.intellij")
    }
    let due = rows.filter { row in
      guard row.place == .mac, row.localBytes != nil, (row.lastActivity ?? .now) < cutoff,
        !busy.contains(row.path)
      else { return false }
      if row.kind == .xcodeDerivedData && xcodeRunning { return false }
      if row.kind == .gradleHome && gradleIDERunning { return false }
      if let at = refused[row.path], at == row.lastActivity { return false }
      return true
    }
    // Shown as queued in the library until their turn.
    queued.formUnion(due.map(\.path))
    defer { queued.subtract(due.map(\.path)) }
    for (i, row) in due.enumerated() {
      queued.remove(row.path)
      if Measure.isBusy(row.candidate) { continue }
      let engine = engine
      let limit = store.offloadLimit
      let paths = row.kind.parts(of: row.candidate.url)?.map(\.path) ?? [row.path]
      let container = row.path
      activity = Self.describe("Stowing", row, index: i, of: due.count)
      operation = .stowing
      busy.insert(row.path)
      defer {
        busy.remove(row.path)
        activity = nil
        operation = nil
      }
      let outcome = await Task.detached { () -> AutoOutcome in
        var outcome = AutoOutcome.stowed
        for path in paths {
          do {
            try engine.adopt(path, kind: row.kind, container: container, limit: limit)
          } catch is OffloadLimitReached {
            return .limit
          } catch {
            // Can't be stowed (a pnpm project, tracked by git…): it stays on the Mac.
            outcome = .refused
          }
        }
        return outcome
      }.value
      if outcome == .limit { break }
      if outcome == .refused { refused[row.path] = row.lastActivity }
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
  /// Whether the free stowage is (nearly) used up: under 5% left, too little for most folders.
  var freeStowageFull: Bool {
    freeAllowanceLeft.map { $0 < Store.freeOffloadLimit / 20 } ?? false
  }
  /// Free stowage left, or nil when stowing is unlimited.
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
      driveName = URL(fileURLWithPath: drive).lastPathComponent
      driveConnected = true
      driveFreeBytes = 812_000_000_000
      driveTotalBytes = 2_000_000_000_000
      driveFormat = "APFS"
      let onMac = rows.filter { $0.place == .mac }.map(\.path)
      if onMac.count > 2 {
        busy = [onMac[0]]
        queued = Set(onMac[1...2])
        operation = .stowing
        activity = rows.first { $0.path == onMac[0] }.map {
          Self.describe("Stowing", $0, index: 0, of: 3)
        }
      }
      driveSpeed = DriveSpeed(
        writeMBps: 2_710, readMBps: 2_950, smallFilesPerSecond: 9_400, measured: .now)
      offloadedBytes = rows.map(\.driveBytes).reduce(0, +)
    }
  }
#endif
