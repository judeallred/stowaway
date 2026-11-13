import Foundation
import StowawayCore

/// Tells a running sweep to stop at its next chance (it's asked between files, off the main
/// thread).
final class SweepGate: @unchecked Sendable {
  private let lock = NSLock()
  private var asked = false
  private var forced = false

  /// For a sweep that gives way to other work.
  var shouldYield: Bool { lock.withLock { asked || forced } }
  /// For an urgent sweep (the drive nearly full): only stopping for good stops it.
  var mustStop: Bool { lock.withLock { forced } }
  /// Other work is waiting.
  func request() { lock.withLock { asked = true } }
  /// The drive is going away (or no longer used): stop, urgent or not.
  func force() { lock.withLock { forced = true } }
  func reset() {
    lock.withLock {
      asked = false
      forced = false
    }
  }
}

/// Sweeping the drive for identical files to share (Engine.sweepSharedFiles). It comes after
/// everything else: it only starts when Stowaway has nothing else to do, and gives way the moment
/// anything starts (stowing, bringing back, deleting, reconciling, a speed test), carrying on
/// next time from where it got to. Except when the drive is nearly full: then getting space back
/// is the work, so it runs at once, at full speed, and doesn't give way.
extension AppModel {
  /// How often a finished sweep runs again (it only reads files that are new or changed).
  static let sweepEvery: TimeInterval = 30 * 60
  static let urgentSweepEvery: TimeInterval = 10 * 60

  /// Anything Stowaway is doing, or about to: a sweep waits for it.
  var otherWorkPending: Bool {
    (operation != nil && operation != .scanning) || !queued.isEmpty || !busy.isEmpty
      || autoStowing || reconcilePending || stowsInFlight > 0 || testingSpeed || stopping
  }

  /// Starts a sweep if it's time and nothing else is going on (or the drive is nearly full).
  func considerSweeping() {
    guard !sweeping, driveConnected, driveCanShare == true, !paused, !ejecting,
      stopIntent == nil, !testingSpeed
    else { return }
    let urgent = driveNearlyFull
    guard urgent || !otherWorkPending else { return }
    // Even when it's urgent, a sweep that just finished has little left to find.
    let every = urgent ? Self.urgentSweepEvery : Self.sweepEvery
    guard sweepUnfinished || Date.now.timeIntervalSince(lastSweep) > every else { return }
    sweeping = true
    sweepGate.reset()
    var options = SweepOptions()
    options.lowPriority = !urgent
    let engine = engine
    let gate = sweepGate
    // When it's urgent, only stopping for good (or pausing, or an eject) stops it.
    let yield: @Sendable () -> Bool = { urgent ? gate.mustStop : gate.shouldYield }
    sweepProgress = nil
    let shown: @Sendable (SweepProgress) -> Void = { [weak self] progress in
      Task { @MainActor in
        if self?.sweeping == true { self?.sweepProgress = progress }
      }
    }
    sweepTask = Task {
      let report = await Task.detached(priority: urgent ? .utility : .background) {
        engine.sweepSharedFiles(options, shouldYield: yield, progress: shown)
      }.value
      sweeping = false
      sweepProgress = nil
      sweepTask = nil
      savedBySharing = engine.savedBySharing()
      switch report.outcome {
      case .finished:
        lastSweep = .now
        sweepUnfinished = false
      case .yielded:
        sweepUnfinished = true
      case .unsupported:
        driveCanShare = false
      case .unavailable, .busy:
        break
      }
      refreshSettings()
    }
  }

  /// Once a day, when nothing else is going on, deletes projects' folders from Cargo's shared
  /// build folder that no build has used in 30 days (deleted worktrees leave theirs behind).
  func pruneCargoBuildFolderIfDue() {
    guard cargoBuildFolderOn, !paused, !ejecting, stopIntent == nil, !sweeping,
      !otherWorkPending, Date.now.timeIntervalSince(lastCargoPrune) > 86_400
    else { return }
    lastCargoPrune = .now
    let engine = engine
    Task {
      let result = await Task.detached(priority: .background) {
        engine.pruneCargoBuildFolder()
      }.value
      if result.folders > 0 { refreshSettings() }
    }
  }

  /// What the running sweep is doing, for the status line.
  var sweepStatus: String {
    let making = driveNearlyFull ? "Making room: " : ""
    switch sweepProgress {
    case .walking(let files)?:
      return files == 0
        ? "\(making)Looking for identical files on the drive…"
        : "\(making)Looking for identical files on the drive: \(files.formatted()) checked…"
    case .reading(let bytes, let total)?:
      return
        "\(making)Looking for identical files: \(Format.bytes(bytes)) of \(Format.bytes(total)) read…"
    case .sharing(let files, let total)?:
      return "\(making)Deduplicating: \(files.formatted()) of \(total.formatted()) files…"
    case nil:
      return "\(making)Looking for identical files on the drive…"
    }
  }

  /// Other work is starting: a running sweep stops at its next chance (unless the drive is
  /// nearly full).
  func makeWayForWork() {
    guard sweeping, !driveNearlyFull else { return }
    sweepGate.request()
  }

  /// Stops a running sweep, whatever the reason, and waits for it (before an eject or stopping
  /// use of the drive).
  func stopSweeping() async {
    guard let task = sweepTask else { return }
    sweepGate.force()
    await task.value
  }

  /// Bytes stowed folders actually take on the drive, sharing counted once.
  var stowedOnDrive: Int64 { max(0, offloadedBytes - savedBySharing) }

  /// What the drive's format means for sharing, when it can't: shown beside the format.
  var sharingUnavailableNote: String? {
    guard driveCanShare == false else { return nil }
    return "\(driveFormat ?? "This format") can't store identical files once; APFS can."
  }
}
