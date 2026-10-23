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
  /// Why a folder on this Mac wasn't stowed, for the library to show.
  var problems: [String: Problem] = [:]
  /// The last few things that went wrong, newest last, for bug reports (kept in memory only).
  var recentFailures: [(date: Date, text: String)] = []
  /// The last few drive choices, newest last, for bug reports: where the panel opened, what it
  /// gave back and what came of it. Described, never as paths, and kept across launches so a
  /// report can follow a relaunch.
  var driveChoices: [String] = UserDefaults.standard.stringArray(forKey: "driveChoices") ?? [] {
    didSet { UserDefaults.standard.set(driveChoices, forKey: "driveChoices") }
  }
  /// Folders whose last stow failed, and when automatic stowing may try again.
  var retryAfter: [String: Date] = [:]
  /// Folders the scan found Stowaway can't stow (pnpm projects…), with the reason.
  var unstowable: [String: String] = [:]
  /// Folders the user chose to keep on this Mac: automatic stowing leaves them alone until
  /// they're stowed by hand or allowed again. Kept across launches.
  var keptOnMac: Set<String> = Set(UserDefaults.standard.stringArray(forKey: "keptOnMac") ?? []) {
    didSet { UserDefaults.standard.set(Array(keptOnMac), forKey: "keptOnMac") }
  }
  /// When folders were brought back. A brought-back folder keeps its old dates, so it would look
  /// idle and be stowed again at once; it's left alone until it changes, then stowed as usual.
  var broughtBack: [String: Date] =
    (UserDefaults.standard.dictionary(forKey: "broughtBack") as? [String: Double] ?? [:])
    .mapValues { Date(timeIntervalSince1970: $0) }
  {
    didSet {
      UserDefaults.standard.set(
        broughtBack.mapValues(\.timeIntervalSince1970), forKey: "broughtBack")
    }
  }
  var roots: [String] = []
  var drivePath: String? {
    didSet { if let drivePath { lastDrivePath = drivePath } }
  }
  /// Where the drive was last seen, kept while it's unplugged and across launches (so its mount
  /// is recognised among the others).
  var lastDrivePath: String? = UserDefaults.standard.string(forKey: "lastDrivePath") {
    didSet { UserDefaults.standard.set(lastDrivePath, forKey: "lastDrivePath") }
  }
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
  /// The user chose to stop using the drive: bring everything back, or delete it. Kept across
  /// launches, so the work carries on after a relaunch or once the drive is back, and automatic
  /// stowing stays off until it's done and the drive is forgotten.
  var stopIntent: StopIntent? = UserDefaults.standard.string(forKey: "stopIntent").flatMap(
    StopIntent.init)
  {
    didSet { UserDefaults.standard.set(stopIntent?.rawValue, forKey: "stopIntent") }
  }
  /// Paused by the user: no automatic stowing and nothing moved onto the drive, though stowed
  /// folders still switch to local ones when the drive goes. Kept across launches.
  var paused = UserDefaults.standard.bool(forKey: "paused") {
    didSet {
      UserDefaults.standard.set(paused, forKey: "paused")
      engine.paused = paused
      if !paused {
        queueReconcile()
        Task { await autoOffload() }
      }
      scheduleDueCheck()
    }
  }
  /// The work of stopping is running now.
  var stopping = false
  var stoppingDrive: Bool { stopIntent != nil }

  enum StopIntent: String {
    case bringBack, delete, quickDrop
  }
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
  /// Watches the project folders, so a new project or install is noticed without polling.
  var watcher: FolderWatcher?
  var lastScan = Date.distantPast
  /// Managed-looking folders a scan looked at and didn't list (a monorepo package's own
  /// node_modules, say): changes there don't call for another scan.
  var setAside: Set<String> = []
  /// Rows whose folder was there at the last scan: only these going away calls for a scan.
  var present: Set<String> = []
  /// Folders whose change asked for the scan that's coming; whatever it doesn't list is set aside.
  var triggers: Set<String> = []
  /// Folders to scan again on their own (a change there), gathered until the rescan runs.
  var dirtyFolders: Set<String> = []
  var rescanScheduled = false
  /// A change arrived while a scan was running or too soon after one: scan again when allowed.
  var scanRequested = false
  var scanScheduled = false
  /// Wakes when the next pending folder becomes due for automatic stowing.
  var dueCheck: Task<Void, Never>?

  /// Stow folders automatically once they've been unchanged this many minutes (see `AutoStow`).
  /// Stored, not read through from UserDefaults, so SwiftUI sees changes.
  var autoOffloadMinutes: Int =
    UserDefaults.standard.object(forKey: "autoOffloadMinutes") == nil
    ? AutoStow.defaultMinutes : UserDefaults.standard.integer(forKey: "autoOffloadMinutes")
  {
    didSet {
      UserDefaults.standard.set(autoOffloadMinutes, forKey: "autoOffloadMinutes")
      Task {
        await autoOffload()
        scheduleDueCheck()
      }
    }
  }

  /// Whether first-run onboarding has been finished or skipped. Never shown again after that;
  /// everything it covers is reachable from the library and Settings.
  var didOnboard: Bool {
    get { UserDefaults.standard.bool(forKey: "didOnboard") }
    set { UserDefaults.standard.set(newValue, forKey: "didOnboard") }
  }

  /// Why a folder isn't stowed.
  enum Problem: Equatable {
    /// Stowaway won't stow it as it is (a pnpm project, a folder git tracks…). Such folders
    /// aren't listed or counted.
    case cantStow(String)
    /// It's pending, and here's why it's taking a while: a tool is using it, or the last try
    /// failed and Stowaway will try again later.
    case waiting(String)

    var reason: String {
      switch self {
      case .cantStow(let text), .waiting(let text): text
      }
    }

    /// The engine's message as a sentence: capitalized, with a full stop.
    static func sentence(_ error: any Error) -> String {
      let text = error.localizedDescription
      let capitalized = text.prefix(1).uppercased() + text.dropFirst()
      return capitalized.hasSuffix(".") ? capitalized : capitalized + "."
    }
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
    /// Mounts and unmounts reconcile at once; this catches the rest (a tool replacing a link,
    /// npm reinstalling packages).
    static let reconcileEvery: TimeInterval = 120
    /// Scans happen when watched folders change; this is the safety net (and how caches outside
    /// the project folders are noticed growing).
    static let scanEvery: TimeInterval = 3600
    /// At most one scan a minute, however busy the folders are.
    static let minScanGap: TimeInterval = 60
    static let recountEvery: TimeInterval = 600
    static let messageShown = Duration.seconds(8)
    /// Mount and unmount notifications come in bursts (a drive and its images).
    static let coalesceVolumeChanges = Duration.milliseconds(150)
    /// "Immediately" still waits this long, so a folder is never copied mid-write.
    static let immediateQuiet: TimeInterval = 30
    static let measuredAtOnce = 4
    /// After a stow fails (not a refusal), automatic stowing waits this long to try again.
    static let retryFailedAfter: TimeInterval = 1800
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

    /// A short status line for the menu and the main window.
    static func status(_ minutes: Int) -> String {
      switch minutes {
      case immediately: "Stows new folders right away"
      case 60: "Stows folders idle for an hour"
      case 1440: "Stows folders idle for a day"
      case 10_080: "Stows folders idle for a week"
      default: "Stows folders idle for \(minutes) minutes"
      }
    }
  }

  // MARK: Starting

  init() {
    engine = Engine()
    engine.cleanupInBackground = true
    engine.paused = UserDefaults.standard.bool(forKey: "paused")
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
    watchFolders()
    timers = [
      Timer.scheduledTimer(withTimeInterval: Timing.reconcileEvery, repeats: true) {
        [weak self] _ in
        Task { @MainActor in self?.queueReconcile() }
      },
      // Changes are watched (watchFolders); this full scan is the safety net.
      Timer.scheduledTimer(withTimeInterval: Timing.scanEvery, repeats: true) { [weak self] _ in
        Task { @MainActor in await self?.scan() }
      },
    ]
    let engine = engine
    Task {
      // A Quick Drop chosen before quitting goes first: it needs no scan, and stowing must not
      // carry on meanwhile.
      if stopIntent == .quickDrop { await continueStopping() }
      // Finish anything a quit or crash interrupted before doing anything else.
      await Task.detached { engine.recover() }.value
      await store.waitUntilLoaded()
      queueReconcile()
      await scan()
      // A stop the user chose before quitting carries on.
      await continueStopping()
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

  /// What the library shows about a row on this Mac that isn't stowed, if anything.
  func problem(for row: Row) -> Problem? {
    guard row.place == .mac else { return nil }
    return problems[row.path] ?? unstowable[row.path].map(Problem.cantStow)
  }

  /// Whether Stowaway can't stow a row as it is (a pnpm project, a folder git tracks…).
  func cantStow(_ row: Row) -> Bool {
    if case .cantStow = problem(for: row) { return true }
    return false
  }

  /// Whether a row can't be stowed: the scan says so, or it was refused and hasn't changed since.
  func isRefused(_ row: Row) -> Bool {
    if unstowable[row.path] != nil { return true }
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
    case idle, scanning, stowing, bringingBack, deleting, testing, disconnected, paused, warning,
      error

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
      case .paused: "pause.circle.fill"
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
      case .paused: "Stowaway, paused"
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
    if paused { return .paused }
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
