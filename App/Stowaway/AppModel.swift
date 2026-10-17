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
  private var reconcileQueued = false

  /// Offload folders automatically once they've been idle this many days (0 = only by hand).
  var autoOffloadDays: Int {
    get { UserDefaults.standard.integer(forKey: "autoOffloadDays") }
    set {
      UserDefaults.standard.set(newValue, forKey: "autoOffloadDays")
      Task { await autoOffload() }
    }
  }

  init() {
    engine = Engine()
    engine.cleanupInBackground = true
  }

  func start() {
    engine.log = { [weak self] line in Task { @MainActor in self?.message = line } }
    store.start()
    refreshSettings()
    showingOnboarding = roots.isEmpty
    watchVolumes()
    timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.queueReconcile() }
    }
    queueReconcile()
    Task { await scan() }
  }

  // MARK: Settings

  func refreshSettings() {
    roots = engine.rootPaths
    drivePath = engine.drivePath
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
    if let current = drivePath, current != url.standardizedFileURL.path, !engine.entries().isEmpty {
      message = "Bring every folder back before choosing a different offload location."
      return
    }
    do {
      try engine.grant(url, as: .drive)
    } catch {
      message = "Couldn't remember that location: \(error.localizedDescription)"
    }
    refreshSettings()
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
  /// to ask for (the one that contains them, so they can be swapped for a link).
  var ungrantedCaches: [(kind: Kind, folder: URL)] {
    var result: [(Kind, URL)] = []
    for kind in Kind.allCases where kind.isGlobal {
      for rel in kind.defaultLocations {
        let path = realHomeDirectory.appendingPathComponent(rel)
        // The sandbox allows checking that a path exists, though not reading it.
        guard FileManager.default.fileExists(atPath: path.path), !isCovered(path.path) else {
          continue
        }
        let parent = path.deletingLastPathComponent()
        if !result.contains(where: { $0.1 == parent }) { result.append((kind, parent)) }
      }
    }
    return result
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

  static func container(of entry: Entry) -> String {
    let marker: String? =
      switch entry.kind {
      case .cargoTarget: "/target/"
      case .xcodeDerivedData: "/DerivedData/"
      default: nil
      }
    if let marker, let range = entry.local.range(of: marker) {
      return String(entry.local[..<range.lowerBound]) + marker.dropLast()
    }
    return entry.local
  }

  private static func projectFolder(of entry: Entry, container: String) -> String? {
    guard entry.kind?.isGlobal != true else { return nil }
    return URL(fileURLWithPath: container).deletingLastPathComponent().path
  }

  /// Measures sizes and recency in the background, a few folders at a time.
  private func measure() async {
    let pending = rows.map { ($0.path, $0.candidate) }
    await withTaskGroup(of: (String, Int64, Date).self) { group in
      var iterator = pending.makeIterator()
      func next() -> Bool {
        guard let (path, candidate) = iterator.next() else { return false }
        group.addTask { (path, Measure.allocatedSize(path), Measure.lastActivity(of: candidate)) }
        return true
      }
      for _ in 0..<4 where next() {}
      for await (path, bytes, date) in group {
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
      engine.offloadLimit = limit
      for path in paths { try engine.adopt(path, kind: row.kind) }
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
        if row.kind == .cargoTarget, FileManager.default.fileExists(atPath: row.path) {
          try Copier.remove(row.candidate.url)
        }
      }
    }
  }

  private func perform(_ row: Row, _ body: @escaping @Sendable (Engine, Int64?) throws -> Void)
    async
  {
    busy.insert(row.path)
    defer { busy.remove(row.path) }
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

  /// Offloads folders idle longer than `autoOffloadDays`, within the free limit.
  private func autoOffload() async {
    let days = autoOffloadDays
    guard days > 0, driveConnected else { return }
    let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
    for row in rows
    where row.place == .mac && (row.lastActivity ?? .now) < cutoff && !row.kind.isGlobal {
      let engine = engine
      let limit = store.offloadLimit
      let paths = row.kind.parts(of: row.candidate.url)?.map(\.path) ?? [row.path]
      let stop = await Task.detached { () -> Bool in
        engine.offloadLimit = limit
        for path in paths {
          do {
            try engine.adopt(path, kind: row.kind)
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
