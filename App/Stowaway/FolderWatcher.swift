import CoreServices
import Foundation

/// Watches folders for changes with FSEvents (which work inside the App Sandbox for folders the
/// user granted), so Stowaway rescans when something changes instead of on a short timer.
/// `onChange` gets the folders whose contents changed. Changes Stowaway makes itself are left
/// out.
@MainActor
final class FolderWatcher {
  private var stream: FSEventStreamRef?
  private let onChange: @MainActor ([String]) -> Void

  init(onChange: @escaping @MainActor ([String]) -> Void) {
    self.onChange = onChange
  }

  /// Watches `paths` (replacing whatever was watched before).
  func watch(_ paths: [String]) {
    stop()
    guard !paths.isEmpty else { return }
    var context = FSEventStreamContext(
      version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil,
      copyDescription: nil)
    let callback: FSEventStreamCallback = { _, info, _, paths, _, _ in
      guard let info else { return }
      let changed = unsafeBitCast(paths, to: NSArray.self) as? [String] ?? []
      MainActor.assumeIsolated {
        Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().onChange(changed)
      }
    }
    guard
      let stream = FSEventStreamCreate(
        nil, callback, &context, paths as CFArray,
        // Changes are gathered for 30 seconds: prompt enough to notice a new folder, and a
        // folder that keeps changing (a build, an editor) is reported once per batch.
        FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 30,
        FSEventStreamCreateFlags(
          kFSEventStreamCreateFlagUseCFTypes | kFSEventStreamCreateFlagIgnoreSelf))
    else { return }
    FSEventStreamSetDispatchQueue(stream, .main)
    FSEventStreamStart(stream)
    self.stream = stream
  }

  func stop() {
    guard let stream else { return }
    FSEventStreamStop(stream)
    FSEventStreamInvalidate(stream)
    FSEventStreamRelease(stream)
    self.stream = nil
  }
}
