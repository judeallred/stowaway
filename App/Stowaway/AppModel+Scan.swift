import Foundation
import StowawayCore

/// Finding re-creatable folders and measuring them.
extension AppModel {
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
    await measure()
    saveCache(candidates)
    await recountStowed()
    await autoOffload()
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
    for entry in entries {
      // The row an entry belongs to: the container recorded when it was stowed.
      let container = entry.container ?? entry.local
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
