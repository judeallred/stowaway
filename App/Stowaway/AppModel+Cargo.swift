import Foundation
import StowawayCore

/// The Cargo build folder setting (see `CargoBuildFolder`): every Rust project and worktree
/// builds straight onto the drive, rather than into its own `target/` to be stowed later.
extension AppModel {
  /// Rust is set up on this Mac (the sandbox can tell a folder exists without reading it).
  var usesRust: Bool {
    FileManager.default.fileExists(atPath: realHomeDirectory.appendingPathComponent(".cargo").path)
  }

  /// Cargo build files stowed so far: what the setting would have sent to the drive directly.
  var stowedCargoBytes: Int64 {
    rows.filter { ($0.kind == .cargoTarget || $0.kind == .cargoCache) && $0.place != .mac }
      .map(\.driveBytes).reduce(0, +)
  }

  /// Stowed Cargo build files past this suggest the setting on the main window.
  static let cargoSuggestionBytes: Int64 = 20_000_000_000

  var showsCargoSuggestion: Bool {
    !cargoBuildFolderOn && !cargoSuggestionDismissed && driveName != nil
      && stowedCargoBytes >= Self.cargoSuggestionBytes
  }

  /// The shared build folder's row, once a scan has found it.
  var cargoBuildRow: Row? { rows.first { $0.kind == .cargoBuild } }

  func setCargoBuildFolder(_ on: Bool) {
    if on { turnOnCargoBuildFolder() } else { turnOffCargoBuildFolder() }
  }

  /// Asks for `~/.cargo` if Stowaway can't reach it yet, then turns the setting on.
  func turnOnCargoBuildFolder() {
    guard !isCovered(CargoBuildFolder.folder.path) else {
      Task { await finishTurningOn() }
      return
    }
    let cargo = realHomeDirectory.appendingPathComponent(".cargo")
    guard
      let url = Panels.chooseFolder(
        "Click Choose to let Stowaway make Cargo's build folder in .cargo and add one line to Cargo's config.",
        at: cargo)
    else { return }
    guard CargoBuildFolder.folder.path.isWithin(url.standardizedFileURL.path) else {
      message = "Stowaway needs your .cargo folder for this, not \(Format.path(url.path))."
      return
    }
    grant(url, as: .root, failure: "Couldn't remember your .cargo folder") { [weak self] in
      Task { await self?.finishTurningOn() }
    }
  }

  private func finishTurningOn() async {
    let engine = engine
    do {
      try await Task.detached { try engine.turnOnCargoBuildFolder() }.value
    } catch {
      message = "Couldn't set up Cargo's build folder: \(error.localizedDescription)"
      return
    }
    cargoBuildFolderOn = true
    // Stow the folder now, while it's empty, so the very first build goes to the drive.
    if driveConnected, cargoBuildRow?.place != .drive {
      await offload([
        Row(kind: .cargoBuild, path: CargoBuildFolder.folder.path, project: nil, place: .mac)
      ])
    }
    await scan()
  }

  /// Takes the line out of Cargo's config and deletes the shared build folder, after asking.
  func turnOffCargoBuildFolder() {
    let row = cargoBuildRow
    let size = row.map { " (\(Format.bytes($0.sortSize)))" } ?? ""
    guard
      Panels.ask(
        "Turn off the Cargo build folder?",
        "Cargo goes back to building in each project's target folder. The shared build folder\(size) is deleted; each project rebuilds the next time you build it.",
        buttons: ["Turn Off"], destructive: [0]) != nil
    else { return }
    let engine = engine
    Task {
      do {
        try await Task.detached { try engine.turnOffCargoBuildFolder() }.value
      } catch {
        message = "Couldn't change Cargo's config: \(error.localizedDescription)"
        return
      }
      cargoBuildFolderOn = false
      if let row { await delete([row]) }
      // Deleting a cache leaves its folder empty; this one's no use to anything now.
      rmdir(CargoBuildFolder.folder.path)
      await scan()
    }
  }
}
