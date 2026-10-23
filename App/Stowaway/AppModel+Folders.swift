import Foundation
import StowawayCore

/// The folders Stowaway looks in: choosing them, suggestions, and the caches it can't reach yet.
extension AppModel {
  /// Asks for a folder to scan. Returns false if the user cancelled.
  @discardableResult
  func addRoot(startingAt directory: URL? = nil, message prompt: String? = nil) -> Bool {
    guard
      let url = Panels.chooseFolder(
        prompt ?? "Choose a folder that holds your projects, such as your code folder.",
        at: directory)
    else { return false }
    grant(url, as: .root, failure: "Couldn't remember that folder")
    return true
  }

  /// Saves a grant off the main thread (making a bookmark can stall while a drive is busy), then
  /// refreshes and rescans. `then` runs once the grant is saved.
  func grant(
    _ url: URL, as role: Engine.GrantRole, failure: String? = nil,
    then: (@MainActor () -> Void)? = nil
  ) {
    let engine = engine
    Task {
      do {
        try await Task.detached { try engine.grant(url, as: role) }.value
        then?()
      } catch {
        message =
          failure.map { "\($0): \(error.localizedDescription)" } ?? error.localizedDescription
      }
      refreshSettings()
      await scan()
    }
  }

  /// Folders dropped on the app's icon: a drive becomes the drive to stow on if none is set yet;
  /// anything else is added to the folders Stowaway looks in.
  func open(_ urls: [URL]) {
    for url in urls {
      let isVolume = (try? url.resourceValues(forKeys: [.isVolumeKey]).isVolume) ?? false
      let role: Engine.GrantRole = isVolume && url.path != "/" && driveName == nil ? .drive : .root
      grant(url, as: role, failure: "Couldn't add \(url.lastPathComponent)")
    }
  }

  /// Creates the sample workspace in a folder the user picks and starts looking in it.
  func createSampleProject() {
    guard
      let parent = Panels.chooseFolder(
        "Choose where to put the sample. Stowaway creates a folder named “\(SampleProject.folderName)” there.",
        at: realHomeDirectory.appendingPathComponent("Documents"))
    else { return }
    do {
      let root = try SampleProject.create(in: parent)
      grant(root, as: .root, failure: "Couldn't add the sample") { [weak self] in
        self?.message =
          "Created a sample in \(Format.path(root.path)). Try stowing, bringing back or deleting it."
      }
    } catch {
      message = "Couldn't create the sample: \(error.localizedDescription)"
    }
  }

  /// The chosen folders with any chosen inside another folded under it: the outer one already
  /// covers them. (Their grants are kept, so removing the outer one leaves them working.)
  var rootGroups: [(root: String, nested: [String])] {
    let sorted = roots.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    let nested = { (path: String, outer: String) in path != outer && path.isWithin(outer) }
    return sorted.filter { root in !sorted.contains { nested(root, $0) } }
      .map { top in (top, sorted.filter { nested($0, top) }) }
  }

  /// Stops looking in a folder, and in any chosen folders inside it. Refused while folders in it
  /// are stowed (see `Engine.revokeRoots`).
  func removeRoot(_ path: String) {
    let nested = rootGroups.first { $0.root == path }?.nested ?? []
    do {
      try engine.revokeRoots([path] + nested)
    } catch {
      Panels.tell("Stowaway still needs \(Format.path(path))", error.localizedDescription)
      return
    }
    refreshSettings()
    Task { await scan() }
  }

  /// Asks for the home folder in one go, which covers projects and every cache. macOS can give
  /// back something narrower; then the per-folder buttons are the way. False if the user
  /// cancelled.
  @discardableResult
  func allowHomeFolder() -> Bool {
    guard
      let url = Panels.chooseFolder(
        "Click Choose to let Stowaway look through your home folder: your projects and every cache, in one step. It reads folder names and sizes, never your files' contents.",
        at: realHomeDirectory)
    else { return false }
    guard url.standardizedFileURL.path == realHomeDirectory.standardizedFileURL.path else {
      message =
        "macOS gave Stowaway \(Format.path(url.path)) rather than your home folder. Allow each cache instead."
      return true
    }
    grant(url, as: .root, failure: "Couldn't remember your home folder")
    return true
  }

  /// Machine-wide caches that exist on this Mac but that Stowaway can't reach yet, with the folder
  /// to ask for (the one that contains them, so they can be swapped for a link). A folder inside
  /// another one on the list is left off: allowing the outer one covers it.
  var ungrantedCaches: [(kind: Kind, folder: URL)] {
    var result: [(kind: Kind, folder: URL)] = []
    for kind in Kind.allCases where kind.isGlobal {
      for rel in kind.defaultLocations {
        let path = realHomeDirectory.appendingPathComponent(rel)
        // The sandbox allows checking that a path exists, though not reading it.
        guard FileManager.default.fileExists(atPath: path.path), !isCovered(path.path) else {
          continue
        }
        let parent = path.deletingLastPathComponent()
        if !result.contains(where: { $0.folder == parent }) { result.append((kind, parent)) }
      }
    }
    return result.filter { candidate in
      !result.contains { other in
        other.folder != candidate.folder && candidate.folder.path.isWithin(other.folder.path)
      }
    }
  }

  /// Where the user seems to keep projects (found with Spotlight), minus folders already
  /// chosen. Falls back to the usual names when Spotlight finds nothing.
  var suggestedProjectFolders: [ProjectFinder.Suggestion] {
    let found = detectedProjectFolders.filter { !isCovered($0.folder.path) }
    if !detectedProjectFolders.isEmpty { return found }
    return ["code", "Developer", "Projects", "src", "dev", "GitHub", "repos", "workspace"]
      .map { realHomeDirectory.appendingPathComponent($0) }
      .filter { FileManager.default.fileExists(atPath: $0.path) && !isCovered($0.path) }
      .map { ProjectFinder.Suggestion(folder: $0, projects: 0) }
  }

  /// How many folders Settings → Suggested Folders would offer.
  var suggestionCount: Int {
    suggestedProjectFolders.filter { $0.projects > 0 }.count + ungrantedCaches.count
  }

  /// Fills `detectedProjectFolders` from Spotlight.
  func detectProjectFolders() async {
    detectedProjectFolders = await ProjectFinder.suggestions()
  }

  func isCovered(_ path: String) -> Bool {
    roots.contains { path.isWithin($0) }
  }
}
