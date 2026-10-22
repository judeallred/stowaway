import Foundation
import StowawayCore

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

  /// Folders that changed: rescan if any is where a project or a new folder could appear.
  /// Changes inside folders Stowaway manages (a build writing into target, npm into
  /// node_modules) don't need a scan: those folders are already known.
  private func foldersChanged(_ changed: [String]) {
    let inside: Set<Substring> = [
      "node_modules", "target", ".next", ".venv", ".git", "DerivedData",
    ]
    let relevant = changed.contains { path in
      !path.split(separator: "/").contains { inside.contains($0) }
    }
    if relevant { requestScan() }
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
  /// long enough), checks what changed, and stows what's due: no full scan needed.
  func scheduleDueCheck() {
    dueCheck?.cancel()
    guard autoOffloadMinutes != AutoStow.never, driveConnected, !paused else { return }
    let window =
      autoOffloadMinutes == AutoStow.immediately
      ? Timing.immediateQuiet : Double(autoOffloadMinutes) * 60
    let next = rows.filter { $0.place == .mac && !isRefused($0) && !isHeldOnMac($0) }
      .compactMap { $0.lastActivity?.addingTimeInterval(window) }
      .filter { $0 > .now }
      .min()
    guard let next else { return }
    dueCheck = Task {
      try? await Task.sleep(for: .seconds(next.timeIntervalSinceNow + 2))
      guard !Task.isCancelled, !scanning else { return }
      await checkActivity()
      await autoOffload()
      scheduleDueCheck()
    }
  }

  /// Updates when each folder on this Mac last changed (cheap: it looks two levels deep).
  func checkActivity() async {
    let candidates = rows.filter { $0.place == .mac }.map(\.candidate)
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
    keptOnMac = keptOnMac.filter { current.contains($0) }
    broughtBack = broughtBack.filter { current.contains($0.key) }
    ScanCache(folders: folders).save()
  }

  /// Measures sizes and recency in the background, a few folders at a time.
  func measure() async {
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
