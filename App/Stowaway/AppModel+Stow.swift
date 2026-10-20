import AppKit
import Foundation
import StowawayCore
import os

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
      // No build folders yet (or all already stowed): nothing to do.
      if paths.isEmpty { return }
    } else {
      paths = [row.path]
    }
    for path in paths {
      try engine.adopt(path, kind: row.kind, container: row.path, limit: limit)
    }
  }

  /// Folders unchanged since this are due for automatic stowing.
  var autoStowCutoff: Date {
    let minutes = autoOffloadMinutes
    return Date().addingTimeInterval(
      minutes == AutoStow.immediately ? -Timing.immediateQuiet : -Double(minutes) * 60)
  }

  /// DerivedData while Xcode runs, Gradle's caches while an IDE that runs Gradle does.
  func ideIsUsing(_ row: Row) -> Bool {
    guard row.kind == .xcodeDerivedData || row.kind == .gradleHome else { return false }
    let running = NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)
    if row.kind == .xcodeDerivedData {
      return running.contains { $0.hasPrefix("com.apple.dt.Xcode") }
    }
    return running.contains {
      $0.hasPrefix("com.google.android.studio") || $0.hasPrefix("com.jetbrains.intellij")
    }
  }

  /// Why folders on this Mac aren't being stowed right now ("2 changed recently, 1 in use"), or
  /// nil if nothing's waiting or some are due.
  var waitingSummary: String? {
    let pending = rows.filter { $0.place == .mac && !isRefused($0) }
    // Queued folders are about to be stowed: nothing to explain.
    guard !pending.isEmpty, queued.isEmpty else { return nil }
    if freeStowageFull { return "Waiting: free stowage is full" }
    let cutoff = autoStowCutoff
    var recent = 0
    var inUse = 0
    var kept = 0
    var retrying = 0
    for row in pending {
      if keptOnMac.contains(row.path) {
        kept += 1
      } else if problems[row.path] == .waiting(Self.cargoInUse) || ideIsUsing(row) {
        inUse += 1
      } else if let at = retryAfter[row.path], at > .now {
        retrying += 1
      } else if (row.lastActivity ?? .now) >= cutoff || isHeldOnMac(row) {
        recent += 1
      } else {
        return nil  // due: stowed at the next pass
      }
    }
    let parts = [
      recent > 0 ? "\(recent) changed recently" : nil,
      inUse > 0 ? "\(inUse) in use" : nil,
      retrying > 0 ? "\(retrying) to retry later" : nil,
      kept > 0 ? "\(kept) kept on this Mac" : nil,
    ].compactMap { $0 }
    return "Waiting: " + parts.joined(separator: ", ")
  }

  static let cargoInUse = "A Cargo build or check is using it. Stowaway stows it once that's done."

  /// Records why a folder wasn't stowed. A refusal keeps automatic stowing away until the folder
  /// changes; any other failure leaves it pending, retried after `Timing.retryFailedAfter`
  /// rather than at every scan (a copy that fails partway is costly to repeat).
  private func noteFailure(_ failure: any Error, for row: Row) {
    let reason = Problem.sentence(failure)
    Self.logger.error("Couldn't stow \(row.path, privacy: .private): \(reason, privacy: .private)")
    if (failure as? StowawayError)?.isRefusal == true {
      refused[row.path] = row.lastActivity
      problems[row.path] = .cantStow(reason)
    } else {
      retryAfter[row.path] = .now.addingTimeInterval(Timing.retryFailedAfter)
      problems[row.path] = .waiting(
        "The last try didn't work, so Stowaway will try again soon: \(reason)")
    }
  }

  static let logger = Logger(subsystem: "com.brooklynspaceport.stowaway", category: "stow")

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
    problems[row.path] = nil
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
      if op == .stowing, Measure.isBusy(row.candidate) {
        queued.remove(row.path)
        problems[row.path] = .waiting(Self.cargoInUse)
        continue
      }
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
      if op == .stowing { noteFailure(failure, for: row) }
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
    let cutoff = autoStowCutoff
    let due = rows.filter { row in
      guard row.place == .mac, (row.lastActivity ?? .now) < cutoff,
        !busy.contains(row.path), !isHeldOnMac(row), !isRefused(row),
        retryAfter[row.path].map({ $0 < .now }) ?? true, !ideIsUsing(row)
      else { return false }
      return true
    }
    // Shown as queued in the library until their turn.
    queued.formUnion(due.map(\.path))
    defer { queued.subtract(due.map(\.path)) }
    for (i, row) in due.enumerated() {
      guard !stoppingDrive else { break }
      if Measure.isBusy(row.candidate) {
        queued.remove(row.path)
        problems[row.path] = .waiting(Self.cargoInUse)
        continue
      }
      let failure = await runOne(row, .stowing, index: i, of: due.count, Self.stow)
      if failure == nil {
        broughtBack[row.path] = nil
        retryAfter[row.path] = nil
      }
      if failure is OffloadLimitReached { break }
      if let failure, !(failure is OffloadLimitReached) { noteFailure(failure, for: row) }
    }
  }
}
