import Foundation

/// Docker owns its VM's lifecycle. These disks are reported, never adopted as caches.
public enum DockerStorage {
  public static let defaultDirectory = "Library/Containers/com.docker.docker/Data/vms/0/data"
  public static let documentation = URL(
    string:
      "https://docs.docker.com/desktop/troubleshoot-and-support/faqs/macfaqs/#how-do-i-move-the-file-to-a-bigger-drive"
  )

  public struct Disk: Sendable, Identifiable {
    public var id: String { path }
    public let path: String
    /// Allocated blocks, not the sparse image's maximum logical size.
    public let allocatedBytes: Int64
    public let maximumBytes: Int64
  }

  /// Checks the default directory and explicitly granted custom disk directories. No recursive
  /// search, and no reading outside the user's grants. A relocated directory can be chosen in
  /// Settings after Docker completes its move.
  public static func disks(roots: [String], home: URL = realHomeDirectory) -> [Disk] {
    let directories = Set(roots + [home.appendingPathComponent(defaultDirectory).path])
    var result: [Disk] = []
    for directory in directories.sorted() {
      for name in ["Docker.raw", "Docker.qcow2"] {
        let path = URL(fileURLWithPath: directory).appendingPathComponent(name).path
        guard roots.contains(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") })
        else { continue }
        var info = stat()
        guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFREG else { continue }
        result.append(
          Disk(path: path, allocatedBytes: Int64(info.st_blocks) * 512, maximumBytes: info.st_size))
      }
    }
    return result
  }

  /// Also protects against treating a directory inside a VM's disk directory as a cache.
  static func refusal(for directory: URL) -> String? {
    let path = directory.standardizedFileURL.path
    let standard = realHomeDirectory.appendingPathComponent(defaultDirectory).path
    if path == standard || path.hasPrefix(standard + "/") || standard.hasPrefix(path + "/") {
      return
        "Docker's VM contains persistent data. Move it using Docker Desktop's Disk image location setting."
    }
    var ancestor = directory
    while ancestor.path != "/" {
      if ["Docker.raw", "Docker.qcow2"].contains(where: {
        FileManager.default.fileExists(atPath: ancestor.appendingPathComponent($0).path)
      }) {
        return
          "Docker's VM contains persistent data. Move it using Docker Desktop's Disk image location setting."
      }
      ancestor.deleteLastPathComponent()
    }
    return nil
  }
}
