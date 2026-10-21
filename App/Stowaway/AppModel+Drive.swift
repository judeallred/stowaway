import AppKit
import Foundation
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

  // MARK: Choosing and forgetting

  func chooseDrive() {
    guard
      let url = Panels.chooseFolder(
        "Choose where stowed folders go: an external drive, or a folder on one.",
        at: URL(fileURLWithPath: "/Volumes"))
    else { return }
    grantDrive(url)
  }

  /// Uses a mounted volume (the panel opens on it; the user confirms).
  func chooseDrive(_ volume: URL) {
    guard
      let url = Panels.chooseFolder(
        "Click Choose to keep stowed folders on \(volume.lastPathComponent).", at: volume)
    else { return }
    grantDrive(url)
  }

  private func grantDrive(_ url: URL) {
    grant(url, as: .drive) { [weak self] in
      // A new drive: test its speed, so Settings can say what it's good for.
      self?.driveSpeed = nil
      Task { await self?.testDriveSpeed() }
    }
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
        "\(folders) are stowed on it. Bring them back to this Mac, which needs room for them, or delete them: your tools re-create them when they need them.",
        buttons: ["Bring Everything Back", "Delete Stowed Folders"], destructive: [1])
      guard let choice else { return }
      // Automatic stowing holds off meanwhile, or it would stow what's being brought back.
      stoppingDrive = true
      Task {
        defer { stoppingDrive = false }
        if choice == 0 { await bringBack(stowed) } else { await delete(stowed) }
        guard engine.entries().isEmpty else {
          message =
            "Some folders couldn't be brought back or deleted, so Stowaway still uses \(name)."
          return
        }
        forgetDrive()
      }
    } else {
      guard
        Panels.ask(
          title,
          "\(folders) are stowed on it, and it isn't connected. Connect it to bring them back. Or forget it anyway: each becomes a local folder your tools rebuild into, and the copies stay on the drive, in its Stowaway.noindex folder.",
          buttons: ["Forget Anyway"], destructive: [0]) != nil
      else { return }
      let engine = engine
      Task {
        do {
          try await Task.detached { try engine.abandonDrive() }.value
        } catch {
          message = error.localizedDescription
        }
        driveForgotten()
      }
    }
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
        center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
          Task { @MainActor in self?.queueReconcile() }
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
