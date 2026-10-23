import Foundation
import StowawayCore
import os

/// Finding re-creatable folders and measuring them.
extension AppModel {
  func scan() async {
    guard !scanning else {
      scanRequested = true
      return
    }
    scanning = true
    lastScan = .now
    // Scanning is housekeeping: shown only while there's nothing else to show yet.
    if activity == nil && rows.isEmpty {
      activity = "Scanning your folders…"
      operation = .scanning
    }
    defer {
      scanning = false
      if operation == .scanning {
        activity = nil
        operation = nil
      }
      scheduleDueCheck()
      if scanRequested {
        scanRequested = false
        requestScan()
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
      rows = merge(candidates: rows.map(\.candidate) + newCaches, entries: engine.entries())
    }
    let candidates = await Task.detached {
      engine.enterGrants()
      return Scanner().scan(roots: roots)
    }.value
    rows = merge(candidates: candidates, entries: engine.entries())
    // Folders that asked for this scan but aren't rows don't ask again.
    let listed = Set(rows.map(\.path))
    setAside.formUnion(triggers.subtracting(listed))
    triggers = []
    present = Set(
      listed.filter { path in
        var st = stat()
        return lstat(path, &st) == 0
      })
    unstowable = await Task.detached {
      var found: [String: String] = [:]
      for c in candidates where c.kind == .node {
        if let reason = Engine.refusal(forNodeModules: c.url) {
          found[c.path] = reason.prefix(1).uppercased() + reason.dropFirst() + "."
        }
      }
      return found
    }.value
    refreshSettings()
    // What changed is quick to find, and it's all automatic stowing needs: stow what's due
    // first, then measure sizes, which takes a while with many folders.
    await checkActivity()
    await autoOffload()
    await measure()
    saveCache(candidates)
    await recountStowed()
    await autoOffload()
  }

  // MARK: Watching

  /// Watches the project folders (not caches, whose contents churn on their own).
  func watchFolders() {
    if watcher == nil {
      watcher = FolderWatcher { [weak self] changed in self?.foldersChanged(changed) }
    }
    watcher?.watch(Scanner.walkable(roots))
  }

  /// Folders that changed: rescan only if a folder Stowaway manages appeared there or went away.
  /// Editors, git and builds change files in project folders all the time; anything else needs
  /// no scan (and rescanning on every change kept the app busy while idle).
  private func foldersChanged(_ changed: [String]) {
    let inside: Set<Substring> = [
      "node_modules", "target", ".next", ".venv", ".git", "DerivedData",
    ]
    let names = Kind.allCases.compactMap { $0.projectRule?.folderName }
    let known = Set(rows.map(\.path))
    for path in Set(changed)
    where !path.split(separator: "/").contains(where: { inside.contains($0) })
      && !guardedByMacOS(path)
    {
      // A managed folder appeared here, or one Stowaway knew of went away.
      for name in names {
        let folder = path.hasSuffix("/") ? path + name : path + "/" + name
        var st = stat()
        let exists = lstat(folder, &st) == 0
        // A new one: scan this folder again (it's small). One that went away is handled below.
        if exists, !known.contains(folder), !setAside.contains(folder) {
          triggers.insert(folder)
          rescanSoon(path)
        }
      }
      // Folders that went away just leave the list: no scan needed.
      let gone = present.filter { row in
        var st = stat()
        return row.isWithin(path) && lstat(row, &st) != 0
      }
      if !gone.isEmpty {
        present.subtract(gone)
        rows.removeAll { gone.contains($0.path) && $0.entryPaths.isEmpty }
      }
    }
  }

  static let scanLog = Logger(subsystem: "com.brooklynspaceport.stowaway", category: "scan")

  /// Whether `path` is in a home folder the scan skips (Desktop, Documents…) and the user didn't
  /// choose: looking there would make macOS ask for permission.
  func guardedByMacOS(_ path: String) -> Bool {
    let home = realHomeDirectory.standardizedFileURL.path
    guard path.isWithin(home), path != home else { return false }
    let first = String(path.dropFirst(home.count + 1).prefix { $0 != "/" })
    guard Scanner.homeSkips.contains(first) else { return false }
    let guarded = home + "/" + first
    return !roots.contains { path.isWithin($0) && $0.isWithin(guarded) }
  }

  /// Gathers a folder to scan again on its own, a few seconds from now.
  private func rescanSoon(_ folder: String) {
    dirtyFolders.insert(folder)
    guard !rescanScheduled else { return }
    rescanScheduled = true
    Task {
      try? await Task.sleep(for: .seconds(5))
      rescanScheduled = false
      await rescan()
    }
  }

  /// Scans just the folders that changed (not every root), updates their rows, and stows what's
  /// due. A full scan running meanwhile covers them instead.
  func rescan() async {
    let folders = dirtyFolders
    dirtyFolders = []
    guard !folders.isEmpty else { return }
    guard !scanning else {
      scanRequested = true
      return
    }
    // A rescan counts as scanning, so a full scan waits for it (and it for one): two would each
    // replace the rows with their own view, and the older could win.
    scanning = true
    defer {
      scanning = false
      scheduleDueCheck()
      if scanRequested {
        scanRequested = false
        requestScan()
      }
    }
    let roots = engine.rootPaths
    let found = await Task.detached {
      folders.flatMap { Scanner().scan(folder: $0, roots: roots) }
    }.value
    Self.scanLog.notice("rescanned \(folders.count) changed folders, found \(found.count)")
    // Rows on this Mac inside these folders are replaced by what was found there now.
    let kept = rows.filter { row in
      !(row.entryPaths.isEmpty && folders.contains { row.path.isWithin($0) })
    }
    rows = merge(candidates: kept.map(\.candidate) + found, entries: engine.entries())
    let listed = Set(rows.map(\.path))
    setAside.formUnion(triggers.subtracting(listed))
    triggers = []
    present.formUnion(found.map(\.path))
    await measure(only: Set(found.map(\.path)))
    await autoOffload()
  }

  /// Brings the rows up to date with the engine right after an operation, instead of at the
  /// next scan: what was stowed, brought back or deleted shows as such, and a following
  /// operation sees it.
  func syncRowsWithEngine() {
    let candidates = rows.map(\.candidate).filter { c in
      var st = stat()
      return lstat(c.path, &st) == 0
    }
    rows = merge(candidates: candidates, entries: engine.entries())
  }

  /// Scans now, or as soon as a minute has passed since the last one.
  func requestScan() {
    if scanning {
      scanRequested = true
      return
    }
    let wait = Timing.minScanGap - Date.now.timeIntervalSince(lastScan)
    guard wait > 0 else {
      Task { await scan() }
      return
    }
    guard !scanScheduled else { return }
    scanScheduled = true
    Task {
      try? await Task.sleep(for: .seconds(wait))
      scanScheduled = false
      await scan()
    }
  }

  /// Wakes when the next pending folder becomes due for automatic stowing (it's been unchanged
  /// long enough), re-checks just the folders due by then, and stows them: no full scan. A
  /// folder that keeps changing keeps moving its time on, so wakes are at least a minute apart.
  func scheduleDueCheck() {
    dueCheck?.cancel()
    guard autoOffloadMinutes != AutoStow.never, driveConnected, !paused else { return }
    let window =
      autoOffloadMinutes == AutoStow.immediately
      ? Timing.immediateQuiet : Double(autoOffloadMinutes) * 60
    let dueAt = rows.filter(isPending)
      .compactMap { row -> (String, Date)? in
        guard let activity = row.lastActivity else { return nil }
        var due = activity.addingTimeInterval(window)
        // Waiting to retry after a failure, or in use when last looked at (a Cargo build, an
        // IDE): due again then, not at the next hourly scan.
        if let retry = retryAfter[row.path] { due = max(due, retry) }
        if problems[row.path] == .waiting(Self.cargoInUse) || ideIsUsing(row) {
          due = max(due, Date.now.addingTimeInterval(Timing.recheckInUse))
        }
        return (row.path, due)
      }
      .filter { $0.1 > .now }
    guard let next = dueAt.map(\.1).min() else { return }
    let wake = max(next, Date.now.addingTimeInterval(Timing.minScanGap))
    let paths = Set(dueAt.filter { $0.1 <= wake }.map(\.0))
    dueCheck = Task {
      try? await Task.sleep(for: .seconds(wake.timeIntervalSinceNow + 2))
      guard !Task.isCancelled, !scanning else { return }
      await checkActivity(of: paths)
      await autoOffload()
      scheduleDueCheck()
    }
  }

  /// Updates when each folder on this Mac last changed (cheap: it looks two levels deep).
  func checkActivity(of paths: Set<String>? = nil) async {
    let candidates = rows.filter { $0.place == .mac && (paths?.contains($0.path) ?? true) }
      .map(\.candidate)
    let dates = await Task.detached {
      var dates: [String: Date] = [:]
      for candidate in candidates { dates[candidate.path] = Measure.lastActivity(of: candidate) }
      return dates
    }.value
    for i in rows.indices {
      if let date = dates[rows[i].path] { rows[i].lastActivity = date }
    }
  }

  /// Combines what the scan found with what's stowed. Stowed parts (a Cargo `target/`'s build
  /// folders, DerivedData's intermediates) roll up into their container's row.
  func merge(candidates: [Candidate], entries: [Entry]) -> [Row] {
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
    // Parts stowed before containers were recorded (a Cargo target's deps, DerivedData's
    // intermediates) belong to the folder of their kind that holds them.
    let splitFolders = candidates.filter { $0.kind == .cargoTarget || $0.kind == .xcodeDerivedData }
    for entry in entries {
      // The row an entry belongs to: the container recorded when it was stowed.
      let container =
        entry.container
        ?? splitFolders.first { $0.kind == entry.kind && entry.local.isWithin($0.path) }?.path
        ?? entry.local
      var row =
        rows[container]
        ?? Row(
          kind: entry.kind ?? .node, path: container,
          project: entry.kind?.isGlobal == true
            ? nil : URL(fileURLWithPath: container).deletingLastPathComponent().path,
          place: .mac)
      row.place = entry.online ? .drive : .driveAway
      row.driveBytes += entry.bytes
      row.entryPaths.append(entry.local)
      rows[container] = row
    }
    return rows.values.sorted { ($0.name, $0.path) < ($1.name, $1.path) }
  }

  /// Saves what this scan found, for the next launch, and forgets folders that are gone.
  func saveCache(_ candidates: [Candidate]) {
    let folders = candidates.compactMap { c in
      measured[c.path].map {
        ScanCache.Folder(
          path: c.path, kind: c.kind.rawValue, project: c.project, bytes: $0.bytes,
          activity: $0.activity)
      }
    }
    let current = Set(candidates.map(\.path))
    measured = measured.filter { current.contains($0.key) }
    // The user's choices are forgotten only once the folder is really gone: a scan can miss a
    // folder that's still there (a chosen folder that couldn't be read this time).
    let stillThere = { (path: String) -> Bool in
      var st = stat()
      return current.contains(path) || lstat(path, &st) == 0
    }
    keptOnMac = keptOnMac.filter(stillThere)
    broughtBack = broughtBack.filter { stillThere($0.key) }
    ScanCache(folders: folders).save()
  }

  /// Measures sizes and recency in the background, a few folders at a time.
  func measure(only paths: Set<String>? = nil) async {
    let pending = rows.filter { paths?.contains($0.path) ?? true }
      .map { ($0.path, $0.candidate, measured[$0.path]) }
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
      for _ in 0..<Timing.measuredAtOnce where next() {}
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
}
