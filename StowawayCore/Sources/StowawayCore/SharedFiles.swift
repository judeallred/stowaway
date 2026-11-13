import CryptoKit
import Darwin
import Foundation
import SQLite3

// Identical files on the drive share their storage: APFS clones (`clonefile`) are copy-on-write,
// so files that start out sharing blocks part ways safely the moment either is written. Stowaway
// finds identical files on the drive and makes them share (the sweep, Sweep.swift), and when it
// copies a file the drive already has, it clones that instead of writing it again.
//
// What's stowed is still counted at full size (sizes, the free limit): sharing is shown as
// space saved on top.

/// What identifies a file's contents without reading them: if any of these changed, the file
/// may have. (Any write changes `ctime`, and nothing can set it back.)
public struct FileStamp: Equatable, Sendable {
  public var inode: UInt64
  public var size: Int64
  /// Allocated bytes, as `st_blocks` counts them: a clone counts in full.
  public var allocated: Int64
  public var modified: Int64
  public var changed: Int64

  init(_ st: stat) {
    inode = UInt64(st.st_ino)
    size = Int64(st.st_size)
    allocated = Int64(st.st_blocks) * 512
    modified = Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
    changed = Int64(st.st_ctimespec.tv_sec) * 1_000_000_000 + Int64(st.st_ctimespec.tv_nsec)
  }

  init(inode: UInt64, size: Int64, allocated: Int64, modified: Int64, changed: Int64) {
    self.inode = inode
    self.size = size
    self.allocated = allocated
    self.modified = modified
    self.changed = changed
  }

  /// The stamp of the file at `path` (not following a symlink), if it's a regular file.
  static func of(_ path: String) -> FileStamp? {
    var st = stat()
    guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
    return FileStamp(st)
  }

  /// When the file last changed in any way.
  var changedDate: Date { Date(timeIntervalSince1970: Double(changed) / 1e9) }
}

/// Files that are never shared: a hard link (replacing one name would split it from the
/// others), and files with flags that make swapping or copying their metadata unsafe
/// (immutable or append-only, and transparently compressed files, whose compressed form lives in
/// an extended attribute).
func isShareable(_ st: stat) -> Bool {
  let unsafeFlags = UInt32(UF_IMMUTABLE | UF_APPEND | SF_IMMUTABLE | SF_APPEND | UF_COMPRESSED)
  return st.st_mode & S_IFMT == S_IFREG && st.st_nlink == 1 && st.st_flags & unsafeFlags == 0
}

enum Cloning {
  /// For tests: called with the folder just after a swap's clone is made beside the file.
  nonisolated(unsafe) static var afterCloning: ((String) -> Void)?

  /// SHA-256 of a file's contents, read without following a symlink, or nil if it can't be read
  /// or it changed while being read (or isn't `expected`).
  static func hash(_ path: String, expected: FileStamp? = nil) -> (Data, FileStamp)? {
    let fd = open(path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { return nil }
    defer { close(fd) }
    // Read once, start to end: no point keeping it in the cache.
    _ = fcntl(fd, F_NOCACHE, 1)
    var before = stat()
    guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG else { return nil }
    let stamp = FileStamp(before)
    if let expected, expected != stamp { return nil }
    var hasher = SHA256()
    let size = 1 << 20
    let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 16)
    defer { buffer.deallocate() }
    while true {
      let n = read(fd, buffer, size)
      if n < 0 {
        if errno == EINTR { continue }
        return nil
      }
      if n == 0 { break }
      hasher.update(bufferPointer: UnsafeRawBufferPointer(start: buffer, count: n))
    }
    var after = stat()
    // Changed while it was read, or the name now leads to another file.
    guard fstat(fd, &after) == 0, FileStamp(after) == stamp, FileStamp.of(path) == stamp else {
      return nil
    }
    return (Data(hasher.finalize()), stamp)
  }

  /// Makes `duplicate` share `keeper`'s storage: clones `keeper` beside it, gives the clone
  /// `duplicate`'s metadata (permissions, extended attributes, ACL, dates), then renames it over
  /// `duplicate` in one step. Both must still match their stamps (so neither changed since they
  /// were found identical); the folder's dates are kept too. Returns the new file's stamp.
  ///
  /// Anything open keeps the file it opened: a rename never touches an open file's contents.
  static func share(
    _ duplicate: String, with keeper: String, duplicateStamp: FileStamp, keeperStamp: FileStamp
  ) throws -> FileStamp {
    var dupStat = stat()
    guard lstat(duplicate, &dupStat) == 0, FileStamp(dupStat) == duplicateStamp,
      isShareable(dupStat)
    else { throw SharingError.changed(duplicate) }
    var keeperStat = stat()
    guard lstat(keeper, &keeperStat) == 0, FileStamp(keeperStat) == keeperStamp,
      isShareable(keeperStat), keeperStat.st_dev == dupStat.st_dev
    else { throw SharingError.changed(keeper) }

    let folder = (duplicate as NSString).deletingLastPathComponent
    var folderStat = stat()
    guard lstat(folder, &folderStat) == 0 else { throw SharingError.failed("reading", folder) }
    // A read-only folder (Go's module cache) is opened up for the swap, then closed again.
    let readOnly = folderStat.st_mode & S_IWUSR == 0
    if readOnly, chmod(folder, folderStat.st_mode | S_IWUSR) != 0 {
      throw SharingError.failed("opening up", folder)
    }
    // Making the clone and swapping it in change the folder's dates, and npm trusts its
    // packages' folder dates: they're put back afterwards, unless something else changed the
    // folder meanwhile (then its change stands). The folder's modification time is checked
    // before each change Stowaway makes and noted after it, so another's change shows.
    var ours = folderStat.st_mtimespec
    var othersChanged = false
    func check() {
      var st = stat()
      if lstat(folder, &st) != 0 || st.st_mtimespec.tv_sec != ours.tv_sec
        || st.st_mtimespec.tv_nsec != ours.tv_nsec
      {
        othersChanged = true
      }
    }
    func note() {
      var st = stat()
      if lstat(folder, &st) == 0 { ours = st.st_mtimespec }
    }
    defer {
      if readOnly { chmod(folder, folderStat.st_mode & 0o7777) }
      check()
      if !othersChanged { setDates(folder, from: folderStat) }
    }

    let temporary = folder + "/" + temporaryPrefix + UUID().uuidString.prefix(8).lowercased()
    check()
    guard clonefile(keeper, temporary, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
      throw SharingError.failed("cloning", keeper)
    }
    note()
    afterCloning?(folder)
    do {
      // Written to while it was cloned: the clone may have caught it halfway.
      guard FileStamp.of(keeper) == keeperStamp else { throw SharingError.changed(keeper) }
      try copyMetadata(from: duplicate, stat: dupStat, to: temporary)
      // Last look: the duplicate mustn't have changed while the clone was made.
      guard FileStamp.of(duplicate) == duplicateStamp else {
        throw SharingError.changed(duplicate)
      }
      check()
      guard rename(temporary, duplicate) == 0 else {
        throw SharingError.failed("swapping", duplicate)
      }
      note()
    } catch {
      check()
      unlink(temporary)
      note()
      throw error
    }
    guard let stamp = FileStamp.of(duplicate) else { throw SharingError.changed(duplicate) }
    return stamp
  }

  /// Makes `destination` a clone of `keeper` with `source`'s metadata: copying `source` onto
  /// the drive without writing what's already there. `destination` mustn't exist.
  static func cloneCopy(
    of source: String, sourceStat: stat, from keeper: String, keeperStamp: FileStamp,
    to destination: String
  ) throws {
    guard FileStamp.of(keeper) == keeperStamp else { throw SharingError.changed(keeper) }
    guard clonefile(keeper, destination, UInt32(CLONE_NOFOLLOW | CLONE_NOOWNERCOPY)) == 0 else {
      throw SharingError.failed("cloning", keeper)
    }
    do {
      guard FileStamp.of(keeper) == keeperStamp else { throw SharingError.changed(keeper) }
      try copyMetadata(from: source, stat: sourceStat, to: destination)
    } catch {
      unlink(destination)
      throw error
    }
  }

  /// Prefix of the clone made beside a file before it's swapped in. A leftover (from a crash
  /// mid-swap) is deleted by the next sweep.
  static let temporaryPrefix = ".stowaway-clone-"

  /// Gives `target` exactly `source`'s extended attributes, ACL, permissions, flags and dates.
  static func copyMetadata(from source: String, stat st: stat, to target: String) throws {
    // The clone came with the keeper's attributes; only the source's may remain.
    let size = listxattr(target, nil, 0, XATTR_NOFOLLOW)
    if size > 0 {
      var names = [CChar](repeating: 0, count: size)
      let got = listxattr(target, &names, size, XATTR_NOFOLLOW)
      if got > 0 {
        var start = 0
        for i in 0..<got where names[i] == 0 {
          let name = String(decoding: names[start..<i].map { UInt8(bitPattern: $0) }, as: UTF8.self)
          // Never in the cloned files (they're not compressed), but never strip it either.
          if name != "com.apple.decmpfs" { removexattr(target, name, XATTR_NOFOLLOW) }
          start = i + 1
        }
      }
    }
    if copyfile(
      source, target, nil, copyfile_flags_t(COPYFILE_XATTR | COPYFILE_ACL | COPYFILE_NOFOLLOW))
      != 0
    {
      throw SharingError.failed("copying the attributes of", source)
    }
    guard chmod(target, st.st_mode & 0o7777) == 0 else {
      throw SharingError.failed("setting the permissions of", target)
    }
    guard setDates(target, from: st) else { throw SharingError.failed("dating", target) }
    // Always: the clone came with the keeper's flags. Only the ones a user can set; the
    // system's aren't for Stowaway to carry over (and refusing them would be taken as lasting).
    var now = stat()
    let flags = st.st_flags & UInt32(UF_SETTABLE)
    if lstat(target, &now) == 0, now.st_flags & UInt32(UF_SETTABLE) != flags,
      lchflags(target, (now.st_flags & ~UInt32(UF_SETTABLE)) | flags) != 0
    {
      throw SharingError.failed("flagging", target)
    }
  }

  /// Sets a file's or folder's creation, modification and access dates to `st`'s.
  @discardableResult
  static func setDates(_ path: String, from st: stat) -> Bool {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_CRTIME | ATTR_CMN_MODTIME | ATTR_CMN_ACCTIME)
    var dates = [st.st_birthtimespec, st.st_mtimespec, st.st_atimespec]
    return dates.withUnsafeMutableBytes { raw in
      setattrlist(path, &list, raw.baseAddress, raw.count, UInt32(FSOPT_NOFOLLOW)) == 0
    }
  }

  /// Bytes of a file that no other file shares (APFS's private size), or nil where the file
  /// system can't say.
  public static func privateSize(_ path: String) -> Int64? {
    var list = attrlist()
    list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    list.commonattr = attrgroup_t(ATTR_CMN_RETURNED_ATTRS)
    list.forkattr = attrgroup_t(ATTR_CMNEXT_PRIVATESIZE)
    var buffer = [UInt8](repeating: 0, count: 64)
    guard
      getattrlist(
        path, &list, &buffer, buffer.count, UInt32(FSOPT_ATTR_CMN_EXTENDED | FSOPT_NOFOLLOW)) == 0
    else { return nil }
    return buffer.withUnsafeBytes { raw in
      // A length, the set of attributes returned, then the size.
      // attribute_set_t: common, volume, directory, file, then fork attributes.
      let returned = raw.loadUnaligned(fromByteOffset: 4 + 16, as: UInt32.self)
      guard returned & UInt32(ATTR_CMNEXT_PRIVATESIZE) != 0 else { return nil }
      return raw.loadUnaligned(fromByteOffset: 4 + 20, as: Int64.self)
    }
  }

  /// Whether the volume `url` is on can clone files (APFS can; ExFAT and HFS+ can't).
  public static func volumeSupportsCloning(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.volumeSupportsFileCloningKey]))?
      .volumeSupportsFileCloning ?? false
  }
}

enum SharingError: Error, CustomStringConvertible {
  /// The file isn't what it was when it was looked at.
  case changed(String)
  case failed(String, String, Int32 = errno)

  /// Whether trying again won't help until the file changes (a permission, a read-only or
  /// locked folder), as opposed to something that may pass (a full drive, the drive going).
  var isLasting: Bool {
    guard case .failed(_, _, let code) = self else { return false }
    return [EPERM, EACCES, EROFS].contains(code)
  }

  var description: String {
    switch self {
    case .changed(let path): "\(path) changed"
    case .failed(let action, let path, let code):
      "\(action) \(path): \(String(cString: strerror(code)))"
    }
  }
}

/// What Stowaway knows about the files on the drive: each one's stamp, its contents' hash once
/// read, and whether it shares its storage with the other files of the same hash. Kept in the
/// app's container (the drive isn't trusted), for one store: another drive starts afresh.
///
/// Every file of a hash marked shared shares the same storage (one is cloned from another, and
/// only ever from one that's marked), so the space saved is, per hash, the size times the
/// number marked, less one. A file that changes in any way drops out (its stamp no longer
/// matches) and is looked at again.
final class SharedIndex: @unchecked Sendable {
  /// Whether a file shares its storage with the other files of its hash.
  enum Sharing: Int64 {
    case no = 0
    case yes = 1
    /// It can't be swapped for a clone (a permission it doesn't give, say): left as it is until
    /// it changes.
    case never = 2
  }

  struct Row: Equatable {
    /// Relative to the store.
    var path: String
    var stamp: FileStamp
    var hash: Data?
    var sharing: Sharing = .no
  }

  private var db: OpaquePointer?
  private let lock = NSLock()
  /// Prepared statements, by their SQL: a sweep runs the same few millions of times.
  private var statements: [String: OpaquePointer] = [:]

  /// Opens (or creates) the index at `url` for the store identified by `identity`, starting
  /// afresh if it was for another one or can't be read.
  init(at url: URL, identity: String) throws {
    if !open(url) || (try? meta("identity")) != identity {
      close()
      for suffix in ["", "-wal", "-shm"] { unlink(url.path + suffix) }
      guard open(url) else { throw StowawayError("couldn't open \(url.path)") }
      try setMeta("identity", identity)
    }
  }

  deinit { close() }

  private func open(_ url: URL) -> Bool {
    guard
      sqlite3_open_v2(
        url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil)
        == SQLITE_OK
    else { return false }
    let schema = """
      PRAGMA journal_mode=WAL;
      PRAGMA user_version=1;
      PRAGMA synchronous=NORMAL;
      CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY, value TEXT);
      CREATE TABLE IF NOT EXISTS files(
        path TEXT PRIMARY KEY, inode INTEGER, size INTEGER, allocated INTEGER, modified INTEGER,
        changed INTEGER, hash BLOB, shared INTEGER NOT NULL DEFAULT 0);
      CREATE INDEX IF NOT EXISTS files_size ON files(size);
      CREATE INDEX IF NOT EXISTS files_hash ON files(hash);
      """
    return sqlite3_exec(db, schema, nil, nil, nil) == SQLITE_OK
  }

  private func close() {
    for statement in statements.values { sqlite3_finalize(statement) }
    statements = [:]
    if let db { sqlite3_close_v2(db) }
    db = nil
  }

  // MARK: Statements

  private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

  private enum Value {
    case int(Int64)
    case text(String)
    case blob(Data?)
  }

  /// Runs `sql` with `values`, calling `row` for each result row.
  private func run(_ sql: String, _ values: [Value] = [], row: ((OpaquePointer) -> Void)? = nil)
    throws
  {
    let statement: OpaquePointer
    if let cached = statements[sql] {
      statement = cached
    } else {
      var prepared: OpaquePointer?
      guard sqlite3_prepare_v2(db, sql, -1, &prepared, nil) == SQLITE_OK, let prepared else {
        throw StowawayError("index: \(String(cString: sqlite3_errmsg(db)))")
      }
      statements[sql] = prepared
      statement = prepared
    }
    defer {
      sqlite3_reset(statement)
      sqlite3_clear_bindings(statement)
    }
    for (i, value) in values.enumerated() {
      let at = Int32(i + 1)
      switch value {
      case .int(let n): sqlite3_bind_int64(statement, at, n)
      case .text(let s): sqlite3_bind_text(statement, at, s, -1, Self.transient)
      case .blob(let data?):
        _ = data.withUnsafeBytes {
          sqlite3_bind_blob(statement, at, $0.baseAddress, Int32($0.count), Self.transient)
        }
      case .blob(nil): sqlite3_bind_null(statement, at)
      }
    }
    while true {
      let step = sqlite3_step(statement)
      if step == SQLITE_ROW {
        row?(statement)
      } else if step == SQLITE_DONE {
        return
      } else {
        throw StowawayError("index: \(String(cString: sqlite3_errmsg(db)))")
      }
    }
  }

  private static func readRow(_ s: OpaquePointer) -> Row {
    let hash: Data? =
      sqlite3_column_type(s, 6) == SQLITE_NULL
      ? nil
      : Data(bytes: sqlite3_column_blob(s, 6), count: Int(sqlite3_column_bytes(s, 6)))
    return Row(
      path: String(cString: sqlite3_column_text(s, 0)),
      stamp: FileStamp(
        inode: UInt64(bitPattern: sqlite3_column_int64(s, 1)), size: sqlite3_column_int64(s, 2),
        allocated: sqlite3_column_int64(s, 3), modified: sqlite3_column_int64(s, 4),
        changed: sqlite3_column_int64(s, 5)),
      hash: hash, sharing: Sharing(rawValue: sqlite3_column_int64(s, 7)) ?? .no)
  }

  private static let columns = "path, inode, size, allocated, modified, changed, hash, shared"

  private func rows(_ sql: String, _ values: [Value] = []) throws -> [Row] {
    var result: [Row] = []
    try run(sql, values) { result.append(Self.readRow($0)) }
    return result
  }

  // MARK: Reading and writing

  func meta(_ key: String) throws -> String? {
    try lock.withLock {
      var value: String?
      try run("SELECT value FROM meta WHERE key = ?", [.text(key)]) {
        value = String(cString: sqlite3_column_text($0, 0))
      }
      return value
    }
  }

  func setMeta(_ key: String, _ value: String) throws {
    try lock.withLock {
      try run("INSERT OR REPLACE INTO meta(key, value) VALUES(?, ?)", [.text(key), .text(value)])
    }
  }

  /// Runs `body` as one transaction: much faster for many writes.
  func batch<T>(_ body: () throws -> T) throws -> T {
    try lock.withLock { try run("BEGIN") }
    do {
      let result = try body()
      try lock.withLock { try run("COMMIT") }
      return result
    } catch {
      try? lock.withLock { try run("ROLLBACK") }
      throw error
    }
  }

  func row(_ path: String) throws -> Row? {
    try lock.withLock {
      try rows("SELECT \(Self.columns) FROM files WHERE path = ?", [.text(path)]).first
    }
  }

  /// Records a file as it is now.
  func put(_ row: Row) throws {
    try lock.withLock {
      try run(
        """
        INSERT OR REPLACE INTO files(path, inode, size, allocated, modified, changed, hash, shared)
        VALUES(?, ?, ?, ?, ?, ?, ?, ?)
        """,
        [
          .text(row.path), .int(Int64(bitPattern: row.stamp.inode)), .int(row.stamp.size),
          .int(row.stamp.allocated), .int(row.stamp.modified), .int(row.stamp.changed),
          .blob(row.hash), .int(row.sharing.rawValue),
        ])
    }
  }

  /// Files known in a folder, a page at a time in path order: the next `limit` after `after`.
  /// (`/` is followed by `0`, so the range is exactly the folder.)
  func rows(in folder: String, after: String? = nil, limit: Int) throws -> [Row] {
    try lock.withLock {
      try rows(
        "SELECT \(Self.columns) FROM files WHERE path > ? AND path < ? ORDER BY path LIMIT ?",
        [.text(after ?? folder + "/"), .text(folder + "0"), .int(Int64(limit))])
    }
  }

  /// Bytes of the files a sweep would read: not read yet, and another file has their size.
  func bytesToRead() throws -> Int64 {
    try lock.withLock {
      var total: Int64 = 0
      try run(
        """
        SELECT SUM(size) FROM files WHERE hash IS NULL AND size IN
          (SELECT size FROM files GROUP BY size HAVING COUNT(*) > 1)
        """
      ) { total = sqlite3_column_int64($0, 0) }
      return total
    }
  }

  /// Files a sweep would swap for a clone: not sharing yet, with a twin that can share.
  func filesToShare() throws -> Int {
    try lock.withLock {
      var total = 0
      try run(
        """
        SELECT COUNT(*) FROM files WHERE shared = 0 AND hash IN
          (SELECT hash FROM files WHERE hash IS NOT NULL GROUP BY hash
           HAVING SUM(shared != 2) > 1 AND SUM(shared = 0) > 0)
        """
      ) { total = Int(sqlite3_column_int64($0, 0)) }
      // One file of each hash not sharing yet is the one the others are cloned from.
      var hashes = 0
      try run(
        """
        SELECT COUNT(*) FROM (SELECT hash FROM files WHERE hash IS NOT NULL GROUP BY hash
          HAVING SUM(shared != 2) > 1 AND SUM(shared = 0) > 0 AND SUM(shared = 1) = 0)
        """
      ) { hashes = Int(sqlite3_column_int64($0, 0)) }
      return max(0, total - hashes)
    }
  }

  /// The first part of every path known: the store's top-level folders.
  func topFolders() throws -> Set<String> {
    try lock.withLock {
      var result: Set<String> = []
      try run(
        "SELECT DISTINCT substr(path, 1, instr(path, '/') - 1) FROM files WHERE instr(path, '/') > 0"
      ) { result.insert(String(cString: sqlite3_column_text($0, 0))) }
      return result
    }
  }

  /// A folder renamed in the store: its files are the same files at new paths.
  func move(_ from: String, to: String) throws {
    try lock.withLock {
      try run(
        "UPDATE OR REPLACE files SET path = ? || substr(path, ?) WHERE path >= ? AND path < ?",
        [.text(to), .int(Int64(from.utf8.count + 1)), .text(from + "/"), .text(from + "0")])
    }
  }

  /// Forgets a file, or everything in a folder (a stowed folder deleted or brought back).
  func forget(_ path: String) throws {
    try lock.withLock {
      try run(
        "DELETE FROM files WHERE path = ? OR (path >= ? AND path < ?)",
        [.text(path), .text(path + "/"), .text(path + "0")])
    }
  }

  /// Files not read yet whose size another file has (only those can have a twin), biggest
  /// first, a page at a time: the next `limit` after `after` (the last row of the page before).
  func unhashedWithTwins(after: Row? = nil, limit: Int = 5000) throws -> [Row] {
    try lock.withLock {
      try rows(
        """
        SELECT \(Self.columns) FROM files WHERE hash IS NULL AND size IN
          (SELECT size FROM files GROUP BY size HAVING COUNT(*) > 1)
          AND (size < ? OR (size = ? AND path > ?))
        ORDER BY size DESC, path LIMIT ?
        """,
        [
          .int(after?.stamp.size ?? Int64.max), .int(after?.stamp.size ?? Int64.max),
          .text(after?.path ?? ""), .int(Int64(limit)),
        ])
    }
  }

  /// Hashes with files not yet sharing, biggest saving first.
  func hashesToShare() throws -> [Data] {
    try lock.withLock {
      var result: [Data] = []
      try run(
        """
        SELECT hash FROM files WHERE hash IS NOT NULL GROUP BY hash
        HAVING SUM(shared != 2) > 1 AND SUM(shared = 0) > 0
        ORDER BY MAX(allocated) * SUM(shared = 0) DESC
        """
      ) { s in
        result.append(
          Data(bytes: sqlite3_column_blob(s, 0), count: Int(sqlite3_column_bytes(s, 0))))
      }
      return result
    }
  }

  /// A hash's files, those already sharing first.
  func files(withHash hash: Data) throws -> [Row] {
    try lock.withLock {
      try rows(
        "SELECT \(Self.columns) FROM files WHERE hash = ? ORDER BY shared = 1 DESC, path",
        [.blob(hash)])
    }
  }

  /// Whether a file of this size has been read: a copy of that size might have a twin.
  func hasHashed(size: Int64) throws -> Bool {
    try lock.withLock {
      var found = false
      try run(
        "SELECT 1 FROM files WHERE size = ? AND hash IS NOT NULL LIMIT 1", [.int(size)]
      ) { _ in found = true }
      return found
    }
  }

  /// Bytes saved by sharing: per hash, the size of each sharing file but one.
  func savedBytes() throws -> Int64 {
    try lock.withLock {
      var total: Int64 = 0
      try run(
        """
        SELECT SUM((n - 1) * a) FROM (SELECT COUNT(*) AS n, MAX(allocated) AS a FROM files
          WHERE shared = 1 AND hash IS NOT NULL GROUP BY hash HAVING n > 1)
        """
      ) { total = sqlite3_column_int64($0, 0) }
      return total
    }
  }

  func count() throws -> Int {
    try lock.withLock {
      var n = 0
      try run("SELECT COUNT(*) FROM files") { n = Int(sqlite3_column_int64($0, 0)) }
      return n
    }
  }
}
