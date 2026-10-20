import Foundation

/// Whether git tracks anything inside a folder, read straight from the repository's index:
/// `/usr/bin/git` is an xcrun shim that refuses to run in the App Sandbox. Stowaway never touches
/// a tracked folder (a committed `node_modules`, for example).
public enum GitTracking: Equatable, Sendable {
  case untracked
  case tracked
  /// The repository's index couldn't be read (outside the folders Stowaway was given, or a
  /// format it doesn't understand). Treated as "don't touch".
  case unknown
}

public enum GitIndex {
  /// Whether git tracks any file under `folder`.
  public static func tracking(of folder: URL) -> GitTracking {
    guard let (root, index) = repository(containing: folder) else { return .untracked }
    // No index at all means nothing is tracked: a repository nothing was ever added to, or a
    // worktree whose record git has since pruned (git itself no longer sees a repository
    // there). An index that's there but can't be read or parsed is another matter.
    var st = stat()
    if lstat(index.path, &st) != 0, errno == ENOENT { return .untracked }
    guard let data = FileManager.default.contents(atPath: index.path), let paths = paths(in: data)
    else {
      return .unknown
    }
    let rel = String(folder.standardizedFileURL.path.dropFirst(root.standardizedFileURL.path.count))
      .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    let prefix = rel + "/"
    return paths.contains { $0 == rel || $0.hasPrefix(prefix) } ? .tracked : .untracked
  }

  /// Whether `folder` is, or directly holds, a git repository (a package cloned by hand into
  /// node_modules, say): uncommitted work could be inside, so Stowaway leaves it alone.
  public static func containsRepository(_ folder: URL) -> Bool {
    func hasGit(_ dir: URL) -> Bool {
      var st = stat()
      return lstat(dir.appendingPathComponent(".git").path, &st) == 0
    }
    if hasGit(folder) { return true }
    for child in subdirectories(of: folder) {
      if hasGit(child) { return true }
      if child.lastPathComponent.hasPrefix("@"), subdirectories(of: child).contains(where: hasGit) {
        return true
      }
    }
    return false
  }

  /// The working tree's root and its index file, for the repository `folder` is in.
  static func repository(containing folder: URL) -> (root: URL, index: URL)? {
    var dir = folder.standardizedFileURL.deletingLastPathComponent()
    while dir.path != "/" {
      let git = dir.appendingPathComponent(".git")
      var isDir: ObjCBool = false
      if FileManager.default.fileExists(atPath: git.path, isDirectory: &isDir) {
        if isDir.boolValue {
          return (dir, git.appendingPathComponent("index"))
        }
        // A worktree or submodule: `.git` is a file saying `gitdir: <path>`.
        if let text = try? String(contentsOf: git, encoding: .utf8),
          let line = text.split(separator: "\n").first(where: { $0.hasPrefix("gitdir:") })
        {
          let path = line.dropFirst("gitdir:".count).trimmingCharacters(in: .whitespaces)
          let gitdir =
            path.hasPrefix("/") ? URL(fileURLWithPath: path) : dir.appendingPathComponent(path)
          return (dir, gitdir.appendingPathComponent("index"))
        }
        return nil
      }
      dir = dir.deletingLastPathComponent()
    }
    return nil
  }

  /// Every path in an index file (versions 2, 3 and 4), or nil if it can't be parsed.
  static func paths(in data: Data) -> [String]? {
    let bytes = [UInt8](data)
    guard bytes.count >= 12, bytes[0..<4] == [0x44, 0x49, 0x52, 0x43] else { return nil }  // "DIRC"
    func u32(_ at: Int) -> Int {
      var value = 0
      for i in 0..<4 { value = value << 8 | Int(bytes[at + i]) }
      return value
    }
    let version = u32(4)
    let count = u32(8)
    guard (2...4).contains(version) else { return nil }
    var paths: [String] = []
    paths.reserveCapacity(count)
    var offset = 12
    var previous: [UInt8] = []
    for _ in 0..<count {
      let start = offset
      guard offset + 62 <= bytes.count else { return nil }
      let high = Int(bytes[offset + 60])
      let flags: Int = high << 8 | Int(bytes[offset + 61])
      offset += 62
      if version >= 3, flags & 0x4000 != 0 { offset += 2 }  // extended flags
      var name: [UInt8]
      if version == 4 {
        // The path is the previous one minus N trailing bytes, plus a NUL-terminated suffix.
        // git's offset varint: each continuation adds one before shifting in the next 7 bits.
        guard offset < bytes.count else { return nil }
        var byte = Int(bytes[offset])
        offset += 1
        var strip = byte & 0x7F
        while byte & 0x80 != 0 {
          guard offset < bytes.count else { return nil }
          byte = Int(bytes[offset])
          offset += 1
          strip = ((strip + 1) << 7) | (byte & 0x7F)
        }
        guard strip <= previous.count, let end = bytes[offset...].firstIndex(of: 0) else {
          return nil
        }
        name = Array(previous.dropLast(strip)) + bytes[offset..<end]
        offset = end + 1
      } else {
        guard let end = bytes[offset...].firstIndex(of: 0) else { return nil }
        name = Array(bytes[offset..<end])
        // Entries are padded with 1–8 NULs to a multiple of 8 bytes.
        let length = end - start
        offset = start + ((length + 8) & ~7)
      }
      previous = name
      paths.append(String(decoding: name, as: UTF8.self))
    }
    // Extensions follow the entries. A split index ("link") keeps most entries in a shared index
    // elsewhere, and a sparse index ("sdir") folds whole directories into one entry, so this list
    // could miss tracked files: fail closed.
    while offset + 8 <= bytes.count - 20 {
      let signature = String(decoding: bytes[offset..<offset + 4], as: UTF8.self)
      if signature == "link" || signature == "sdir" { return nil }
      offset += 8 + u32(offset + 4)
    }
    return paths
  }
}
