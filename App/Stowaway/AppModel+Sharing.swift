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
  private var otherWorkPending: Bool {
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
    sweepTask = Task {
      let report = await Task.detached(priority: urgent ? .utility : .background) {
        engine.sweepSharedFiles(options, shouldYield: yield)
      }.value
      sweeping = false
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
