import AppKit
import Foundation
import StowawayCore

/// Stowing, bringing back and deleting, by hand and automatically.
extension AppModel {
  /// One folder's work: runs off the main thread with the current limit.
  typealias Work = @Sendable (Row, Engine, Int64?) throws -> Void

  /// Stows each folder in turn. With several, folders Stowaway can't stow (a pnpm project, say)
  /// are skipped rather than stopping the rest.
  func offload(_ rows: [Row]) async {
    guard drivePath != nil else {
      message = "Choose where to stow first."
      return
    }
    // Stowing by hand undoes "keep on this Mac".
    keptOnMac.subtract(rows.map(\.path))
    for row in rows { broughtBack[row.path] = nil }
    await bulk(rows, .stowing, Self.stow)
  }

  /// Brings folders back. With `keep`, they stay on this Mac until stowed by hand; otherwise
  /// automatic stowing takes them again once they've changed and gone quiet.
  func bringBack(_ rows: [Row], keep: Bool = false) async {
    if keep {
      keptOnMac.formUnion(rows.map(\.path))
    } else {
      for row in rows { broughtBack[row.path] = .now }
    }
    await bulk(rows, .bringingBack) { row, engine, _ in
      for path in row.entryPaths { try engine.release(path) }
    }
  }

  /// Keeps folders on this Mac, out of automatic stowing; stowed ones are brought back first.
  func keepOnMac(_ rows: [Row]) async {
    keptOnMac.formUnion(rows.map(\.path))
    let stowed = rows.filter { $0.place != .mac }
    if !stowed.isEmpty { await bringBack(stowed, keep: true) }
  }

  /// Lets automatic stowing take folders that were kept on this Mac.
  func allowAutomaticStowing(_ rows: [Row]) {
    keptOnMac.subtract(rows.map(\.path))
    for row in rows { broughtBack[row.path] = nil }
    Task { await autoOffload() }
  }

  /// Whether automatic stowing should leave a folder alone because the user kept it here, or
  /// brought it back and it hasn't changed since.
  func isHeldOnMac(_ row: Row) -> Bool {
    if keptOnMac.contains(row.path) { return true }
    guard let at = broughtBack[row.path] else { return false }
    return (row.lastActivity ?? .distantPast) <= at
  }

  func delete(_ rows: [Row]) async {
    let roots = roots
    await bulk(rows, .deleting) { row, engine, _ in
      if row.entryPaths.isEmpty {
        try engine.delete(row.candidate, roots: roots)
      } else {
        for path in row.entryPaths { try engine.discard(path) }
        // A Cargo target's remaining local part (built programs) goes too: delete means delete.
        if row.kind == .cargoTarget, FileManager.default.fileExists(atPath: row.path) {
          try engine.delete(row.candidate, roots: roots)
        }
      }
    }
  }

  /// Stows a row: its parts (a Cargo target's build folders) or the whole folder.
  nonisolated private static func stow(_ row: Row, _ engine: Engine, _ limit: Int64?) throws {
    let paths: [String]
    if let parts = row.kind.parts(of: row.candidate.url) {
      paths = parts.map(\.path).filter { !row.entryPaths.contains($0) }
      if paths.isEmpty { throw StowawayError("\(row.name) has no build folders to stow yet.") }
    } else {
      paths = [row.path]
    }
    for path in paths {
      try engine.adopt(path, kind: row.kind, container: row.path, limit: limit)
    }
  }

  /// "Stowing node_modules in alchemist (2.8 GB) · 3 of 12…"
  static func describe(_ op: Operation, _ row: Row, index: Int, of count: Int) -> String {
    let what = row.project == nil ? row.kind.label : "\(row.kind.label) in \(row.name)"
    let bytes = row.place == .mac ? row.localBytes : row.driveBytes
    var text = "\(op.verb) \(what)"
    if let bytes, bytes > 0 { text += " (\(Format.bytes(bytes)))" }
    if count > 1 { text += " · \(index + 1) of \(count)" }
    return text + "…"
  }

  /// Runs one folder's work off the main thread, marking it busy and describing it meanwhile.
  private func runOne(
    _ row: Row, _ op: Operation, index: Int, of count: Int, _ work: @escaping Work
  )
    async -> (any Error)?
  {
    activity = Self.describe(op, row, index: index, of: count)
    operation = op
    queued.remove(row.path)
    busy.insert(row.path)
    defer {
      busy.remove(row.path)
      activity = nil
      operation = nil
    }
    let engine = engine
    let limit = store.offloadLimit
    return await Task.detached { () -> (any Error)? in
      do {
        try work(row, engine, limit)
        return nil
      } catch {
        return error
      }
    }.value
  }

  /// Runs `work` for each row, one at a time, then rescans once. One row's failure is shown;
  /// with several, failures are skipped. Reaching the free limit stops the run and offers the
  /// upgrade.
  private func bulk(_ rows: [Row], _ op: Operation, _ work: @escaping Work) async {
    // Rows another operation is already working on are left to it.
    let rows = rows.filter { !busy.contains($0.path) }
    guard !rows.isEmpty else { return }
    await store.waitUntilLoaded()
    if op == .stowing { queued.formUnion(rows.map(\.path)) }
    defer { queued.subtract(rows.map(\.path)) }
    var failures: [any Error] = []
    for (i, row) in rows.enumerated() {
      let failure = await runOne(row, op, index: i, of: rows.count, work)
      if failure is OffloadLimitReached {
        if store.loaded {
          showingSupport = true
        } else {
          message = "Stowaway is still checking your purchases. Try again in a moment."
        }
        break
      }
      guard let failure else { continue }
      failures.append(failure)
      if op == .stowing, (failure as? StowawayError)?.isRefusal == true {
        refused[row.path] = row.lastActivity
      }
    }
    if rows.count == 1, let error = failures.first { message = error.localizedDescription }
    await scan()
  }

  /// Stows folders unchanged for `autoOffloadMinutes`, within the free limit. Skips folders a
  /// tool is using right now (a running Cargo build, DerivedData while Xcode runs, Gradle's
  /// caches while an IDE that runs Gradle does), folders the user brought back, and ones that
  /// couldn't be stowed and haven't changed since.
  func autoOffload() async {
    let minutes = autoOffloadMinutes
    guard minutes != AutoStow.never, driveConnected, !stoppingDrive else { return }
    await store.waitUntilLoaded()
    // Until purchases are read, the free limit could hold back a paying user's folders.
    guard store.loaded else { return }
    let cutoff = Date().addingTimeInterval(
      minutes == AutoStow.immediately ? -Timing.immediateQuiet : -Double(minutes) * 60)
    let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
    let xcodeRunning = running.contains { $0.hasPrefix("com.apple.dt.Xcode") }
    let gradleIDERunning = running.contains {
      $0.hasPrefix("com.google.android.studio") || $0.hasPrefix("com.jetbrains.intellij")
    }
    let due = rows.filter { row in
      guard row.place == .mac, row.localBytes != nil, (row.lastActivity ?? .now) < cutoff,
        !busy.contains(row.path), !isHeldOnMac(row), !isRefused(row)
      else { return false }
      if row.kind == .xcodeDerivedData && xcodeRunning { return false }
      if row.kind == .gradleHome && gradleIDERunning { return false }
      return true
    }
    // Shown as queued in the library until their turn.
    queued.formUnion(due.map(\.path))
    defer { queued.subtract(due.map(\.path)) }
    for (i, row) in due.enumerated() {
      guard !stoppingDrive else { break }
      if Measure.isBusy(row.candidate) {
        queued.remove(row.path)
        continue
      }
      let failure = await runOne(row, .stowing, index: i, of: due.count, Self.stow)
      if failure == nil { broughtBack[row.path] = nil }
      if failure is OffloadLimitReached { break }
      // Only real refusals are remembered; a failure that may pass is retried next time.
      if (failure as? StowawayError)?.isRefusal == true { refused[row.path] = row.lastActivity }
    }
  }
}
