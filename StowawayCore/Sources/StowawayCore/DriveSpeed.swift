import Foundation

/// How fast the offload location is, measured where offloaded folders live. Builds on an
/// offloaded folder read and write there, and node_modules is thousands of small files, so the
/// test times both large transfers and small files.
public struct DriveSpeed: Codable, Sendable, Equatable {
  /// Megabytes per second, writing and then reading one large file, bypassing the cache.
  public let writeMBps: Double
  public let readMBps: Double
  /// Small files (4 KB) created and written per second.
  public let smallFilesPerSecond: Double
  public let measured: Date

  public init(writeMBps: Double, readMBps: Double, smallFilesPerSecond: Double, measured: Date) {
    self.writeMBps = writeMBps
    self.readMBps = readMBps
    self.smallFilesPerSecond = smallFilesPerSecond
    self.measured = measured
  }

  public enum Rating: Sendable {
    /// Fine for building on the drive, even with "Immediately".
    case fast
    /// Fine for offloading; builds on the drive are slower than on the Mac.
    case moderate
    /// Better for folders you don't use often.
    case slow
  }

  public var rating: Rating {
    if writeMBps >= 400 && readMBps >= 400 && smallFilesPerSecond >= 2_000 { return .fast }
    if writeMBps >= 80 && readMBps >= 80 && smallFilesPerSecond >= 300 { return .moderate }
    return .slow
  }

  static let folderPrefix = ".stowaway-speedtest-"

  /// Measures in a temporary folder inside `store`, removed afterwards (and on the next run, if
  /// a crash left one behind). Takes a few seconds; call it off the main thread.
  public static func measure(
    in store: URL, bytes: Int = 256 << 20, smallFiles: Int = 2_000
  ) throws -> DriveSpeed {
    let fm = FileManager.default
    for name in (try? fm.contentsOfDirectory(atPath: store.path)) ?? []
    where name.hasPrefix(folderPrefix) {
      try? Copier.remove(store.appendingPathComponent(name))
    }
    let folder = store.appendingPathComponent(folderPrefix + UUID().uuidString)
    try fm.createDirectory(at: folder, withIntermediateDirectories: false)
    defer { try? Copier.remove(folder) }

    let file = folder.appendingPathComponent("large").path
    let chunk = [UInt8](repeating: 0xA5, count: 8 << 20)
    let write = try timed {
      let fd = open(file, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
      guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
      defer { close(fd) }
      _ = fcntl(fd, F_NOCACHE, 1)
      var left = bytes
      while left > 0 {
        let n = chunk.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, min(left, chunk.count)) }
        guard n > 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        left -= n
      }
      _ = fcntl(fd, F_FULLFSYNC)
    }
    var buffer = [UInt8](repeating: 0, count: 8 << 20)
    let read = try timed {
      let fd = open(file, O_RDONLY)
      guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
      defer { close(fd) }
      _ = fcntl(fd, F_NOCACHE, 1)
      while buffer.withUnsafeMutableBytes({ Darwin.read(fd, $0.baseAddress, $0.count) }) > 0 {}
    }
    let small = folder.appendingPathComponent("small")
    try fm.createDirectory(at: small, withIntermediateDirectories: false)
    let block = [UInt8](repeating: 0x5A, count: 4096)
    let files = try timed {
      for i in 0..<smallFiles {
        let fd = open(small.appendingPathComponent("f\(i)").path, O_WRONLY | O_CREAT, 0o600)
        guard fd >= 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
        _ = block.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
      }
      let dir = open(small.path, O_RDONLY)
      if dir >= 0 {
        _ = fcntl(dir, F_FULLFSYNC)
        close(dir)
      }
    }
    let mb = Double(bytes) / 1_000_000
    return DriveSpeed(
      writeMBps: mb / write, readMBps: mb / read,
      smallFilesPerSecond: Double(smallFiles) / files, measured: Date())
  }

  private static func timed(_ work: () throws -> Void) throws -> Double {
    let start = DispatchTime.now().uptimeNanoseconds
    try work()
    return max(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e9, 0.001)
  }
}
