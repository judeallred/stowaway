import Darwin
import Foundation

/// What a copy did.
public struct CopyStats: Sendable, CustomStringConvertible {
  public var files = 0
  public var directories = 0
  public var bytes: Int64 = 0
  public var seconds = 0.0
  /// Packages already on the drive, relinked without copying.
  public var reused = 0

  public var description: String {
    (reused > 0 ? "\(reused) unchanged packages relinked, " : "")
      + String(
        format: "%d files, %d dirs, %.1f MB in %.2fs (%.0f MB/s, %.0f files/s)", files, directories,
        Double(bytes) / 1e6, seconds, Double(bytes) / 1e6 / max(seconds, 0.001),
        Double(files) / max(seconds, 0.001))
  }
}

/// Copies trees with a pool of workers, like the core engine's `fsutil::copy_tree`: one pass
/// creates directories in order, then regular files and symlinks are copied in parallel (per-file
/// latency dominates for node_modules-style trees), then directory metadata is applied deepest
/// first so read-only directories don't block their own contents.
public enum Copier {
  public static var workers: Int { min(ProcessInfo.processInfo.activeProcessorCount, 16) }

  /// Copies the contents of `src` into `dst`, creating `dst` if needed. Existing files in `dst`
  /// are replaced, so this also merges.
  public static func copyContents(of src: URL, into dst: URL) throws -> CopyStats {
    let start = Date()
    var stats = CopyStats()
    let fm = FileManager.default
    try fm.createDirectory(at: dst, withIntermediateDirectories: true)

    var dirs: [(String, String)] = []
    var leaves: [(String, String)] = []
    let srcPath = src.standardizedFileURL.path
    let dstPath = dst.standardizedFileURL.path
    guard let walker = fm.enumerator(atPath: srcPath) else {
      throw StowawayError("can't read \(srcPath)")
    }
    while let rel = walker.nextObject() as? String {
      let from = srcPath + "/" + rel
      let to = dstPath + "/" + rel
      var st = stat()
      guard lstat(from, &st) == 0 else { throw StowawayError.posix("reading", from) }
      if st.st_mode & S_IFMT == S_IFDIR {
        if mkdir(to, 0o700) != 0 && errno != EEXIST { throw StowawayError.posix("creating", to) }
        dirs.append((from, to))
      } else {
        leaves.append((from, to))
        if st.st_mode & S_IFMT == S_IFREG { stats.bytes += Int64(st.st_size) }
      }
    }

    let failure = Failure()
    let jobs = leaves
    DispatchQueue.concurrentPerform(iterations: workers) { worker in
      var i = worker
      while i < jobs.count, !failure.isSet {
        let (from, to) = jobs[i]
        unlink(to)
        if copyfile(from, to, nil, copyfile_flags_t(COPYFILE_ALL | COPYFILE_NOFOLLOW)) != 0 {
          failure.set(StowawayError.posix("copying", from))
        }
        i += workers
      }
    }
    if let error = failure.error { throw error }

    for (from, to) in dirs.reversed() {
      copyfile(from, to, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
    }
    copyfile(srcPath, dstPath, nil, copyfile_flags_t(COPYFILE_METADATA | COPYFILE_NOFOLLOW))
    stats.files = leaves.count
    stats.directories = dirs.count
    stats.seconds = Date().timeIntervalSince(start)
    return stats
  }

  /// Deletes a tree as fast as `rm -rf`. Works relative to open directory handles (`unlinkat`), so
  /// each delete resolves a short name rather than a long path, and it's thread-safe (no chdir).
  /// Read-only directories are made writable first (Go's module cache). Symlinks aren't followed.
  public static func remove(_ url: URL) throws {
    var st = stat()
    guard lstat(url.path, &st) == 0 else { return }
    if st.st_mode & S_IFMT != S_IFDIR {
      if unlink(url.path) != 0 { throw StowawayError.posix("deleting", url.path) }
      return
    }
    let parent = open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
    guard parent >= 0 else {
      throw StowawayError.posix("opening", url.deletingLastPathComponent().path)
    }
    defer { close(parent) }
    try removeDirectory(named: url.lastPathComponent, in: parent, path: url.path)
  }

  private static func removeDirectory(named name: String, in parent: Int32, path: String) throws {
    var fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    if fd < 0, errno == EACCES {
      fchmodat(parent, name, 0o700, AT_SYMLINK_NOFOLLOW)
      fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
    }
    guard fd >= 0 else { throw StowawayError.posix("opening", path) }
    if faccessat(parent, name, W_OK, AT_EACCESS) != 0 { fchmod(fd, 0o700) }
    guard let dir = fdopendir(fd) else {
      close(fd)
      throw StowawayError.posix("reading", path)
    }
    var children: [(String, Bool)] = []
    while let entry = readdir(dir) {
      let child = withUnsafeBytes(of: entry.pointee.d_name) { raw in
        raw.bindMemory(to: CChar.self).baseAddress.map { String(cString: $0) } ?? ""
      }
      if child.isEmpty || child == "." || child == ".." { continue }
      children.append((child, Int32(entry.pointee.d_type) == DT_DIR))
    }
    defer { closedir(dir) }  // also closes fd
    for (child, isDir) in children {
      if isDir {
        try removeDirectory(named: child, in: fd, path: path + "/" + child)
      } else if unlinkat(fd, child, 0) != 0 {
        throw StowawayError.posix("deleting", path + "/" + child)
      }
    }
    if unlinkat(parent, name, AT_REMOVEDIR) != 0 { throw StowawayError.posix("deleting", path) }
  }
}

private final class Failure: @unchecked Sendable {
  private let lock = NSLock()
  private var first: (any Error)?

  var isSet: Bool { lock.withLock { first != nil } }
  var error: (any Error)? { lock.withLock { first } }
  func set(_ error: any Error) { lock.withLock { if first == nil { first = error } } }
}

extension StowawayError {
  static func posix(_ action: String, _ path: String) -> StowawayError {
    StowawayError("\(action) \(path): \(String(cString: strerror(errno)))")
  }
}
