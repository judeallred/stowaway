import AppKit
import Foundation
import ServiceManagement
import StowawayCore

/// The app's state and actions. Engine work runs off the main actor; results come back here.
///
/// The work lives in extensions by area: AppModel+Folders (what Stowaway looks in), +Scan,
/// +Stow (stowing, bringing back, deleting, automatic stowing) and +Drive. Their state is
/// declared here, since stored properties must be; only AppModel and its extensions set it.
@MainActor @Observable
final class AppModel {
  let engine: Engine
  let store = Store()

  // MARK: State

  var rows: [Row] = []
  var scanning = false
  /// Folders an operation is working on right now.
  var busy: Set<String> = []
  /// Folders waiting their turn to be stowed.
  var queued: Set<String> = []
  /// Folders Stowaway couldn't stow (a pnpm project, say), with their last-changed date then.
  /// Automatic stowing leaves them alone until they change.
  var refused: [String: Date?] = [:]
  /// Folders the user brought back: automatic stowing leaves them on this Mac until they're
  /// stowed by hand. Kept across launches.
  var keptOnMac: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "keptOnMac") ?? []) {
    didSet { UserDefaults.standard.set(Array(keptOnMac), forKey: "keptOnMac") }
  }
  var roots: [String] = []
  var drivePath: String?
  /// The drive's name, known even while it's unplugged.
  var driveName: String?
  var driveConnected = false
  var driveFreeBytes: Int64?
  var driveTotalBytes: Int64?
  /// The drive's format, such as "APFS" or "ExFAT".
  var driveFormat: String?
  /// The last speed test of the drive (kept until the drive changes).
  var driveSpeed: DriveSpeed? = UserDefaults.standard.data(forKey: "driveSpeed").flatMap {
    try? JSONDecoder().decode(DriveSpeed.self, from: $0)
  }
  {
    didSet {
      UserDefaults.standard.set(
        driveSpeed.flatMap { try? JSONEncoder().encode($0) }, forKey: "driveSpeed")
    }
  }
  var testingSpeed = false
  var offloadedBytes: Int64 = 0
  var loginItemEnabled = false
  /// What Stowaway is doing right now ("Scanning…", what's moving), for the status line.
  var activity: String?
  /// The kind of work `activity` describes, for the menu bar icon and the library's rows.
  var operation: Operation?
  /// Set while the user is stopping using the drive, so automatic stowing holds off.
  var stoppingDrive = false
  /// A problem with something the user just did. Cleared after a few seconds: the status line
  /// is for what's happening now, not a log.
  var message: String? {
    didSet {
      guard let message else { return }
      Task {
        try? await Task.sleep(for: Timing.messageShown)
        if self.message == message { self.message = nil }
      }
    }
  }
  var showingSupport = false
  var showingOnboarding = false
  var started = false
  /// Opens the library window (set by the menu bar label, which has SwiftUI's openWindow).
  var openLibrary: (() -> Void)?

  var watchers: [any NSObjectProtocol] = []
  var timers: [Timer] = []
  /// Last measurement per folder, so a rescan only re-measures folders that changed.
  var measured: [String: (bytes: Int64, activity: Date)] = [:]
  /// A reconcile is waiting or running (they're coalesced, never stacked).
  var reconcilePending = false
  /// When stowed folders were last re-measured on the drive.
  var lastRecount = Date.distantPast
  var detectedProjectFolders: [ProjectFinder.Suggestion] = []

  /// Stow folders automatically once they've been unchanged this many minutes (see `AutoStow`).
  /// Stored, not read through from UserDefaults, so SwiftUI sees changes.
  var autoOffloadMinutes: Int =
    UserDefaults.standard.object(forKey: "autoOffloadMinutes") == nil
    ? AutoStow.defaultMinutes : UserDefaults.standard.integer(forKey: "autoOffloadMinutes")
  {
    didSet {
      UserDefaults.standard.set(autoOffloadMinutes, forKey: "autoOffloadMinutes")
      Task { await autoOffload() }
    }
  }

  /// Whether first-run onboarding has been finished or skipped. Never shown again after that;
  /// everything it covers is reachable from the library and Settings.
  var didOnboard: Bool {
    get { UserDefaults.standard.bool(forKey: "didOnboard") }
    set { UserDefaults.standard.set(newValue, forKey: "didOnboard") }
  }

  // MARK: Kinds of work

  enum Operation {
    case scanning, stowing, bringingBack, deleting, testing

    /// For the status line: "Stowing node_modules in alchemist…".
    var verb: String {
      switch self {
      case .scanning: "Scanning"
      case .stowing: "Stowing"
      case .bringingBack: "Bringing back"
      case .deleting: "Deleting"
      case .testing: "Testing"
      }
    }
  }

  /// How long things take or wait.
  enum Timing {
    static let reconcileEvery: TimeInterval = 30
    static let scanEvery: TimeInterval = 120
    static let recountEvery: TimeInterval = 600
    static let messageShown = Duration.seconds(8)
    /// Mount and unmount notifications come in bursts (a drive and its images).
    static let coalesceVolumeChanges = Duration.milliseconds(150)
    /// "Immediately" still waits this long, so a folder is never copied mid-write.
    static let immediateQuiet: TimeInterval = 30
    static let measuredAtOnce = 4
  }

  /// The choices for stowing automatically.
  enum AutoStow {
    static let immediately = -1
    static let never = 0
    static let defaultMinutes = 5
    static let choices: [(minutes: Int, label: String)] = [
      (immediately, "Immediately"),
      (5, "After 5 minutes unchanged"),
      (60, "After 1 hour unchanged"),
      (1440, "After 1 day unchanged"),
      (10_080, "After 1 week unchanged"),
      (never, "Never (only when I choose)"),
    ]

    /// "after 5 minutes unchanged", for sentences.
    static func describe(_ minutes: Int) -> String {
      switch minutes {
      case immediately: "as soon as Stowaway finds them"
      case never: "only when you choose"
      default:
        (choices.first { $0.minutes == minutes }?.label ?? "after \(minutes) minutes")
          .lowercased()
      }
    }
  }

  // MARK: Starting

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
    timers = [
      Timer.scheduledTimer(withTimeInterval: Timing.reconcileEvery, repeats: true) {
        [weak self] _ in
        Task { @MainActor in self?.queueReconcile() }
      },
      // Look again every couple of minutes, so automatic stowing keeps up with new folders.
      Timer.scheduledTimer(withTimeInterval: Timing.scanEvery, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.scan() }
      },
    ]
    let engine = engine
    Task {
      // Finish anything a quit or crash interrupted before doing anything else.
      await Task.detached { engine.recover() }.value
      await store.waitUntilLoaded()
      queueReconcile()
      await scan()
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

  // MARK: Totals

  /// Whether a row couldn't be stowed and hasn't changed since.
  func isRefused(_ row: Row) -> Bool {
    if let at = refused[row.path], at == row.lastActivity { return true }
    return false
  }

  /// Bytes of re-creatable folders on this Mac.
  var reclaimableBytes: Int64 {
    rows.filter { $0.place == .mac }.compactMap(\.localBytes).reduce(0, +)
  }

  /// Bytes on this Mac still to be stowed: every re-creatable folder here that Stowaway can stow
  /// (folders it couldn't, such as a pnpm project, are left out until they change). Stowed plus
  /// pending is `eligibleBytes`.
  var pendingBytes: Int64 {
    rows.filter { $0.place == .mac && !isRefused($0) }.compactMap(\.localBytes).reduce(0, +)
  }

  /// All the re-creatable data Stowaway manages: what's stowed plus what's pending.
  var eligibleBytes: Int64 { offloadedBytes + pendingBytes }

  /// Free stowage left, or nil when stowing is unlimited.
  var freeAllowanceLeft: Int64? {
    store.offloadLimit.map { max(0, $0 - offloadedBytes) }
  }

  /// Whether the free stowage is (nearly) used up: under 5% left, too little for most folders.
  var freeStowageFull: Bool {
    freeAllowanceLeft.map { $0 < Store.freeOffloadLimit / 20 } ?? false
  }

  /// The drive's symbol: connected or not.
  var driveSymbol: String { driveConnected ? "externaldrive.fill" : "externaldrive.badge.xmark" }

  // MARK: Menu bar icon

  /// What the menu bar icon shows: the plain logo when all is well, or a small badge for
  /// what's happening now or what needs attention. Problems outrank work in progress.
  enum IconState {
    case idle, scanning, stowing, bringingBack, deleting, testing, disconnected, warning, error

    /// The SF Symbol on the logo's corner, nil for the plain logo. Badges never animate.
    var badge: String? {
      switch self {
      case .idle: nil
      case .scanning: "magnifyingglass"
      case .stowing: "arrow.down"
      case .bringingBack: "arrow.uturn.backward"
      case .deleting: "trash.fill"
      case .testing: "speedometer"
      case .disconnected: "xmark.circle.fill"
      case .warning: "exclamationmark.circle.fill"
      case .error: "exclamationmark.triangle.fill"
      }
    }

    /// Spoken by VoiceOver.
    var description: String {
      switch self {
      case .idle: "Stowaway"
      case .scanning: "Stowaway, scanning folders"
      case .stowing: "Stowaway, stowing folders on the drive"
      case .bringingBack: "Stowaway, bringing folders back"
      case .deleting: "Stowaway, deleting folders"
      case .testing: "Stowaway, testing the drive"
      case .disconnected: "Stowaway, drive disconnected"
      case .warning: "Stowaway, needs attention"
      case .error: "Stowaway, problem"
      }
    }
  }

  var iconState: IconState {
    if message != nil { return .error }
    if driveName != nil && !driveConnected { return .disconnected }
    switch operation {
    case .stowing: return .stowing
    case .bringingBack: return .bringingBack
    case .deleting: return .deleting
    case .testing: return .testing
    case .scanning: return .scanning
    case nil: break
    }
    return needsAttention ? .warning : .idle
  }

  /// The drive is nearly full (under 5% or 10 GB free), or the free stowage is used up while
  /// there's more waiting to be stowed.
  private var needsAttention: Bool {
    if driveConnected, let free = driveFreeBytes, let total = driveTotalBytes, total > 0,
      free < max(10_000_000_000, total / 20)
    {
      return true
    }
    return freeStowageFull && pendingBytes > 0 && autoOffloadMinutes != AutoStow.never
  }
}

#if DEBUG
  extension AppModel {
    /// Snapshots (Snapshots.swift) only: the state a connected drive mid-stow would have.
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
          Self.describe(.stowing, $0, index: 0, of: 3)
        }
      }
      driveSpeed = DriveSpeed(
        writeMBps: 2_710, readMBps: 2_950, smallFilesPerSecond: 9_400, measured: .now)
      offloadedBytes = rows.map(\.driveBytes).reduce(0, +)
    }
  }
#endif
