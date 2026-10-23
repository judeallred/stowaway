import AppKit
import Foundation
import OSLog
import ServiceManagement
import StowawayCore

/// The drive: choosing it, stopping using it, its space and speed, and keeping links in step as
/// it comes and goes.
extension AppModel {
  /// Reads the folders, drive and login setting. Everything that touches the drive runs off the
  /// main thread: a drive busy with a big copy can take seconds to answer.
  func refreshSettings() {
    let before = roots
    roots = engine.rootPaths
    if roots != before, started { watchFolders() }
    driveName = engine.driveName
    loginItemEnabled = SMAppService.mainApp.status == .enabled
    let engine = engine
    Task.detached {
      let drivePath = engine.drivePath
      let store = engine.enterGrants()
      let values = store.flatMap {
        try? $0.resourceValues(forKeys: [
          .volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey,
          .volumeLocalizedFormatDescriptionKey,
        ])
      }
      let free = values?.volumeAvailableCapacityForImportantUsage
      let total = values?.volumeTotalCapacity.map(Int64.init)
      let format = values?.volumeLocalizedFormatDescription
      let bytes = engine.offloadedBytes
      await MainActor.run {
        self.drivePath = drivePath
        self.driveConnected = store != nil
        self.driveFreeBytes = free
        self.driveTotalBytes = total
        self.driveFormat = format
        self.offloadedBytes = bytes
      }
    }
  }

  /// Measures the drive's speed (a few seconds; writes and removes a 256 MB file).
  func testDriveSpeed() async {
    guard !testingSpeed else { return }
    testingSpeed = true
    activity = "Testing the drive's speed…"
    operation = .testing
    defer {
      testingSpeed = false
      activity = nil
      operation = nil
      // Stowing waited for the test.
      Task { await autoOffload() }
    }
    let engine = engine
    let result = await Task.detached { () -> Result<DriveSpeed, Error>? in
      guard let store = engine.enterGrants() else { return nil }
      return Result { try DriveSpeed.measure(in: store) }
    }.value
    switch result {
    case .success(let speed): driveSpeed = speed
    case .failure(let error): message = "Couldn't test the drive: \(error.localizedDescription)"
    case nil: message = "Connect your drive to test it."
    }
  }

  /// Ejects the drive: stowed folders switch to local ones first, as when it's unplugged. If
  /// macOS can't eject it (something's using it), they link up again.
  func ejectDrive() {
    guard let path = drivePath, let name = driveName else { return }
    let drive = URL(fileURLWithPath: path)
    let volume = (try? drive.resourceValues(forKeys: [.volumeURLKey]).volume) ?? drive
    let engine = engine
    engine.paused = true
    ejecting = true
    activity = "Ejecting \(name)…"
    Task {
      await Task.detached { engine.prepareForEject() }.value
      do {
        try await FileManager.default.unmountVolume(
          at: volume, options: [.allPartitionsAndEjectDisk])
      } catch {
        message = "Couldn't eject \(name): \(error.localizedDescription)"
      }
      engine.paused = paused
      ejecting = false
      activity = nil
      queueReconcile()
    }
  }

  // MARK: Choosing and forgetting

  /// Choosing the first drive opens inside it when only one is connected: the panel on /Volumes lists
  /// "Macintosh HD" (a link to /) beside the drives, and a click meant for the drive can land on
  /// it, notably while the drive is still mounting and the list shifts. Changing drives, or
  /// `anywhere` (for "Somewhere Else…" beside a button for the drive), opens on /Volumes.
  func chooseDrive(anywhere: Bool = false) {
    if !anywhere, driveName == nil, externalVolumes.count == 1, let volume = externalVolumes.first {
      chooseDrive(volume)
      return
    }
    let volumes = URL(fileURLWithPath: "/Volumes")
    let url = Panels.chooseFolder(
      "Choose where stowed folders go: an external drive, or a folder on one.", at: volumes)
    grantDrive(url, openedAt: volumes)
  }

  /// Uses a mounted volume (the panel opens on it; the user confirms).
  func chooseDrive(_ volume: URL) {
    let url = Panels.chooseFolder(
      "Click Choose to keep stowed folders on \(volume.lastPathComponent).", at: volume)
    grantDrive(url, openedAt: volume)
  }

  /// Checks and saves the panel's answer (nil if cancelled), noting the choice for bug reports.
  private func grantDrive(_ url: URL?, openedAt start: URL) {
    let opened =
      start.path == "/Volumes"
      ? "on /Volumes" : "inside \(Self.describeLocation(start, relativeTo: nil))"
    let attempt =
      "Window opened \(opened), with \(Format.count(externalVolumes.count, "external drive")) connected"
    guard let url else {
      noteDriveChoice("\(attempt); cancelled")
      return
    }
    let got = "\(attempt); got \(Self.describeLocation(url, relativeTo: start))"
    if let problem = Self.whyNotADrive(url) {
      let buttons = problem.canUseAnyway ? ["Choose Another…", "Use Anyway"] : ["Choose Another…"]
      let choice = Panels.ask(problem.title, problem.detail, buttons: buttons)
      noteDriveChoice(
        "\(got); warned, then \(choice == 1 ? "used anyway" : choice == 0 ? "chose again" : "cancelled")"
      )
      if choice == 0 { chooseDrive() }
      guard choice == 1 else { return }  // 1 is Use Anyway
    } else {
      noteDriveChoice("\(got); used")
    }
    grant(url, as: .drive) { [weak self] in
      // A new drive: test its speed, so Settings can say what it's good for.
      self?.driveSpeed = nil
      Task { await self?.testDriveSpeed() }
    }
  }

  private func noteDriveChoice(_ text: String) {
    Self.driveLog.info("\(text, privacy: .public)")
    let time = Date.now.formatted(.dateTime.month(.abbreviated).day().hour().minute().second())
    driveChoices.append("\(time)  \(text)")
    if driveChoices.count > 5 { driveChoices.removeFirst(driveChoices.count - 5) }
  }

  static let driveLog = Logger(subsystem: "com.brooklynspaceport.stowaway", category: "drive")

  /// What kind of place a location is, without naming it: "/", this Mac's own disk, the top of
  /// an external drive, a folder on one… and whether it's on the volume the panel opened on.
  static func describeLocation(_ url: URL, relativeTo start: URL?) -> String {
    let keys: Set<URLResourceKey> = [
      .volumeURLKey, .volumeIsRootFileSystemKey, .volumeIsInternalKey, .volumeIsReadOnlyKey,
      .volumeIdentifierKey,
    ]
    guard let values = try? url.resourceValues(forKeys: keys) else {
      return "a location that couldn't be read"
    }
    let topLevel = values.volume?.standardizedFileURL.path == url.standardizedFileURL.path
    var text: String
    if url.standardizedFileURL.path == "/" {
      text = "/ (this Mac's own disk)"
    } else if values.volumeIsRootFileSystem == true {
      text = topLevel ? "the top of this Mac's own disk" : "a folder on this Mac's own disk"
    } else if values.volumeIsInternal == true {
      text = topLevel ? "the top of another internal disk" : "a folder on another internal disk"
    } else {
      text = topLevel ? "the top of an external drive" : "a folder on an external drive"
    }
    if values.volumeIsReadOnly == true { text += ", read-only" }
    if let start, start.path != "/Volumes" {
      let startVolume = try? start.resourceValues(forKeys: [.volumeIdentifierKey])
      let same =
        (values.volumeIdentifier as? NSObject).map { $0.isEqual(startVolume?.volumeIdentifier) }
        ?? false
      if !same { text += ", not the drive the window opened in" }
    }
    return text
  }

  /// Why a chosen location is a poor place for stowed folders, if it is. This Mac's own disk
  /// frees nothing (and its system volume is read-only); macOS can hand it back even when the
  /// user meant a drive, since the panel opens on /Volumes, where "Macintosh HD" (a link to /)
  /// sits beside the drives. Another internal disk works but frees nothing on a one-disk Mac, so
  /// it's a warning the user can override.
  static func whyNotADrive(_ url: URL) -> (title: String, detail: String, canUseAnyway: Bool)? {
    let keys: Set<URLResourceKey> = [
      .volumeIsRootFileSystemKey, .volumeIsReadOnlyKey, .volumeIsInternalKey,
      .volumeIdentifierKey, .volumeLocalizedNameKey,
    ]
    guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
    let name = values.volumeLocalizedName ?? url.lastPathComponent
    let home = try? realHomeDirectory.resourceValues(forKeys: [.volumeIdentifierKey])
    let onHomeVolume =
      (values.volumeIdentifier as? NSObject).map { $0.isEqual(home?.volumeIdentifier) } ?? false
    if values.volumeIsRootFileSystem == true || onHomeVolume {
      return (
        "That’s this Mac’s own disk, \(name)",
        "Stowing frees space by moving folders to another drive, so it can’t use this one. If you meant an external drive, select it under Locations in the window’s sidebar, then click Choose.",
        false
      )
    }
    if values.volumeIsReadOnly == true {
      return (
        "\(name) is read-only", "Stowaway needs a drive it can write to. Choose another drive.",
        false
      )
    }
    if values.volumeIsInternal == true {
      return (
        "\(name) is inside this Mac",
        "Stowing there frees space only if it’s a different disk from the one your projects are on. An external drive is usually what you want.",
        true
      )
    }
    return nil
  }

  /// External drives that are mounted now, for choosing one in one click. Read-only volumes
  /// (installer disk images, for example) are left off.
  var externalVolumes: [URL] {
    let keys: [URLResourceKey] = [
      .volumeIsInternalKey, .volumeIsRootFileSystemKey, .volumeIsBrowsableKey,
      .volumeIsReadOnlyKey,
    ]
    let volumes =
      FileManager.default.mountedVolumeURLs(
        includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes])
      ?? []
    return volumes.filter {
      let values = try? $0.resourceValues(forKeys: Set(keys))
      return values?.volumeIsRootFileSystem != true && values?.volumeIsInternal != true
        && values?.volumeIsBrowsable != false && values?.volumeIsReadOnly != true
    }
  }

  /// Stops using the drive, after asking how: with folders stowed on it, bring them all back or
  /// delete them; with the drive away, forget it and leave its copies there.
  func stopUsingDrive() {
    guard let name = driveName else { return }
    let stowed = rows.filter { !$0.entryPaths.isEmpty }
    let title = "Stop using \(name)?"
    if stowed.isEmpty {
      if Panels.ask(
        title, "Nothing is stowed on it. You can choose a drive again any time.",
        buttons: ["Stop Using"]) != nil
      {
        forgetDrive()
      }
      return
    }
    let folders =
      "\(Format.count(stowed.count, "folder")) (\(Format.bytes(stowed.map(\.driveBytes).reduce(0, +))))"
    if driveConnected {
      let choice = Panels.ask(
        title,
        "\(folders) are stowed on it. Bring them back to this Mac (it needs room for them), or delete them. Or drop them quickly: each becomes a local folder your tools rebuild into, and the copies stay on the drive, in its Stowaway.noindex folder.",
        buttons: ["Bring Everything Back", "Delete Stowed Folders", "Quick Drop"],
        destructive: [1, 2])
      switch choice {
      case 0: stopIntent = .bringBack
      case 1: stopIntent = .delete
      case 2: quickDrop()
      default: return
      }
      Task { await continueStopping() }
    } else {
      guard
        Panels.ask(
          title,
          "\(folders) are stowed on it, and it isn't connected. Connect it to bring them back. Or forget it anyway: each becomes a local folder your tools rebuild into, and the copies stay on the drive, in its Stowaway.noindex folder.",
          buttons: ["Forget Anyway"], destructive: [0]) != nil
      else { return }
      quickDrop()
    }
  }

  /// Stops using the drive at once: stowed folders become local ones and the links are gone;
  /// the copies on the drive are left alone. Recorded first, so stowing stops before the next
  /// folder and a relaunch finishes the drop.
  private func quickDrop() {
    stopIntent = .quickDrop
    Task { await continueStopping() }
  }

  /// Carries on bringing everything back (or deleting it) after the user chose to stop using
  /// the drive; then forgets the drive. Runs when chosen, at launch, and when the drive returns.
  func continueStopping() async {
    guard let intent = stopIntent, !stopping, driveName != nil else { return }
    stopping = true
    defer { stopping = false }
    if intent == .quickDrop {
      let engine = engine
      do {
        try await Task.detached { try engine.abandonDrive() }.value
      } catch {
        message = error.localizedDescription
        return
      }
      stopIntent = nil
      driveForgotten()
      return
    }
    guard driveConnected else { return }  // resumes when the drive is back
    let stowed = rows.filter { !$0.entryPaths.isEmpty }
    if intent == .bringBack { await bringBack(stowed) } else { await delete(stowed) }
    guard engine.entries().isEmpty else {
      message = "Some folders couldn't be brought back or deleted yet; Stowaway will keep trying."
      return
    }
    stopIntent = nil
    forgetDrive()
  }

  private func forgetDrive() {
    do {
      try engine.forgetDrive()
    } catch {
      message = error.localizedDescription
    }
    driveForgotten()
  }

  private func driveForgotten() {
    driveSpeed = nil
    refreshSettings()
    Task { await scan() }
  }

  // MARK: The drive coming and going

  func watchVolumes() {
    let center = NSWorkspace.shared.notificationCenter
    for name in [NSWorkspace.didMountNotification, NSWorkspace.didUnmountNotification] {
      watchers.append(
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
          // macOS mounts and unmounts volumes all the time (Time Machine snapshots, disk
          // images); only the drive's own matter.
          let volume = (note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL)?.path
          Task { @MainActor in
            guard let self, self.driveName != nil else { return }
            if let drive = self.lastDrivePath, let volume, !drive.isWithin(volume) { return }
            self.queueReconcile()
          }
        })
    }
  }

  /// Reconciles soon. Requests coalesce, and while one is waiting or running no other starts:
  /// a long stow holds the engine's lock, and reconciles queued behind it would each tie up a
  /// thread.
  func queueReconcile() {
    guard !reconcilePending else { return }
    reconcilePending = true
    Task {
      defer { reconcilePending = false }
      try? await Task.sleep(for: Timing.coalesceVolumeChanges)
      let engine = engine
      await Task.detached { engine.reconcile() }.value
      let entries = engine.entries()
      for i in rows.indices where !rows[i].entryPaths.isEmpty {
        let online = entries.filter { rows[i].entryPaths.contains($0.local) }.allSatisfy(\.online)
        rows[i].place = online ? .drive : .driveAway
      }
      refreshSettings()
      if stopIntent != nil { Task { await continueStopping() } }
    }
  }

  /// At most every 10 minutes, re-measures stowed folders on the drive, so the stowed total
  /// keeps up with tools that write into them.
  func recountStowed() async {
    guard driveConnected, Date.now.timeIntervalSince(lastRecount) > Timing.recountEvery else {
      return
    }
    lastRecount = .now
    let engine = engine
    await Task.detached { engine.recountStowed() }.value
    rows = merge(candidates: rows.map(\.candidate), entries: engine.entries())
    refreshSettings()
  }
}
