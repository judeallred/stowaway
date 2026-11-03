import Foundation

/// Persistent VM storage must never use the empty-folder fallback intended for caches.
enum DockerStorage {
  private static let defaultDirectory = "Library/Containers/com.docker.docker/Data/vms/0/data"

  /// Also protects against treating a directory inside a VM's disk directory as a cache.
  static func refusal(for directory: URL) -> String? {
    let path = directory.standardizedFileURL.path
    let standard = realHomeDirectory.appendingPathComponent(defaultDirectory).path
    if path == standard || path.hasPrefix(standard + "/") || standard.hasPrefix(path + "/") {
      return
        "Docker's VM contains persistent data and isn't a recreatable cache."
    }
    var ancestor = directory
    while ancestor.path != "/" {
      if ["Docker.raw", "Docker.qcow2"].contains(where: {
        FileManager.default.fileExists(atPath: ancestor.appendingPathComponent($0).path)
      }) {
        return
          "Docker's VM contains persistent data and isn't a recreatable cache."
      }
      ancestor.deleteLastPathComponent()
    }
    return nil
  }
}
