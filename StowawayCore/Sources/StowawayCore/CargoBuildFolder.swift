import Foundation

/// Cargo's `build.build-dir` (Rust 1.91+) puts a build's intermediate files (dependencies,
/// incremental and build-script output) in one folder instead of each project's `target/`, which
/// keeps only the programs it builds. Turned on, Stowaway points it at a folder in `~/.cargo`
/// that it stows like any cache: a link to the drive, or a local folder while the drive is away.
/// So every project and worktree builds onto the drive from its first build, with nothing to
/// stow afterwards. `{workspace-path-hash}` gives each project its own folder inside.
///
/// It's one line in Cargo's own config (`~/.cargo/config.toml`), added and removed by Stowaway,
/// and marked so it's never confused with a setting of the user's.
public enum CargoBuildFolder {
  /// The shared build folder, relative to the home folder.
  public static let location = ".cargo/stowaway-build"
  public static var folder: URL { realHomeDirectory.appendingPathComponent(location) }
  /// What `build-dir` is set to.
  public static var setting: String { folder.path + "/{workspace-path-hash}" }

  /// Cargo's config file: `config.toml`, or the older `config` when that's the one in use
  /// (Cargo reads `config` when both exist).
  public static func configFile(
    in cargoHome: URL = realHomeDirectory.appendingPathComponent(".cargo")
  )
    -> URL
  {
    let legacy = cargoHome.appendingPathComponent("config")
    return FileManager.default.fileExists(atPath: legacy.path)
      ? legacy : cargoHome.appendingPathComponent("config.toml")
  }

  /// Marks the line Stowaway adds.
  static let marker = "# Added by Stowaway (turn off in its Settings)"

  /// Whether `config` has Stowaway's line.
  public static func isOn(in config: String) -> Bool {
    lines(config).contains(where: isOurs)
  }

  /// `config` with Stowaway's `build-dir` line added (or put right, if it's there already).
  /// Refuses a config that sets `build-dir` itself, or describes `build` in a way a line can't
  /// be added to safely (an inline table).
  public static func turningOn(_ config: String, setting: String = setting) throws -> String {
    var lines = lines(turningOff(config))
    var table: String? = nil
    var buildHeader: Int?
    for (i, line) in lines.enumerated() {
      let code = stripComment(line).trimmingCharacters(in: .whitespaces)
      if let name = tableName(code) {
        table = name
        if name == "build", buildHeader == nil { buildHeader = i }
        continue
      }
      guard let key = keyName(code) else { continue }
      let full = table.map { "\($0).\(key)" } ?? key
      if full == "build.build-dir" {
        throw StowawayError.refusal(
          "Your Cargo config already sets build-dir. Stowaway leaves your own setting alone.")
      }
      if table == nil, key == "build" {
        throw StowawayError.refusal(
          "Your Cargo config describes build on one line, which Stowaway can't add to safely.")
      }
    }
    let value = "\"\(escaped(setting))\""
    if let buildHeader {
      lines.insert("build-dir = \(value)  \(marker)", at: buildHeader + 1)
    } else {
      // A dotted key before any table belongs to the top level, wherever else build is set.
      lines.insert("build.build-dir = \(value)  \(marker)", at: 0)
    }
    var text = lines.joined(separator: "\n")
    if !text.hasSuffix("\n") { text += "\n" }
    return text
  }

  /// `config` without Stowaway's line; everything else as it was.
  public static func turningOff(_ config: String) -> String {
    guard isOn(in: config) else { return config }
    let kept = lines(config).filter { !isOurs($0) }
    let text = kept.joined(separator: "\n")
    return text.isEmpty || text.hasSuffix("\n") ? text : text + "\n"
  }

  // MARK: Reading TOML, as much as this needs

  private static func lines(_ text: String) -> [String] {
    var lines = text.components(separatedBy: "\n")
    if lines.last == "" { lines.removeLast() }
    return lines
  }

  private static func isOurs(_ line: String) -> Bool {
    line.hasSuffix(marker)
      && keyName(stripComment(line).trimmingCharacters(in: .whitespaces))
        .map { $0 == "build-dir" || $0 == "build.build-dir" } == true
  }

  /// The table a `[name]` header opens (not an array of tables, `[[name]]`).
  private static func tableName(_ code: String) -> String? {
    guard code.hasPrefix("["), !code.hasPrefix("[["), code.hasSuffix("]") else { return nil }
    return unquote(String(code.dropFirst().dropLast()))
  }

  /// The key a `key = value` line sets, with dotted parts joined by dots and quotes removed.
  private static func keyName(_ code: String) -> String? {
    guard let equals = code.firstIndex(of: "="), !code.hasPrefix("[") else { return nil }
    let key = unquote(String(code[..<equals]))
    return key.isEmpty ? nil : key
  }

  /// `a . "b" . c` as `a.b.c`.
  private static func unquote(_ key: String) -> String {
    key.split(separator: ".").map {
      $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(
        in: CharacterSet(charactersIn: "\"'"))
    }
    .joined(separator: ".")
  }

  /// A line without its comment (a `#` outside a string).
  private static func stripComment(_ line: String) -> String {
    var quote: Character?
    var previous: Character?
    for (i, c) in zip(line.indices, line) {
      if let q = quote {
        if c == q, !(q == "\"" && previous == "\\") { quote = nil }
      } else if c == "\"" || c == "'" {
        quote = c
      } else if c == "#" {
        return String(line[..<i])
      }
      previous = c
    }
    return line
  }

  private static func escaped(_ s: String) -> String {
    s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
  }
}

extension Engine {
  /// Whether Cargo's config has Stowaway's build folder line. False if it can't be read.
  public func cargoBuildFolderIsOn() -> Bool {
    enterGrants()
    guard
      let text = try? String(contentsOf: CargoBuildFolder.configFile(), encoding: .utf8)
    else { return false }
    return CargoBuildFolder.isOn(in: text)
  }

  /// Creates the shared build folder and points Cargo at it. Needs `~/.cargo` (or the home
  /// folder) to have been granted.
  public func turnOnCargoBuildFolder() throws {
    try exclusively {
      enterGrants()
      let folder = CargoBuildFolder.folder
      guard isInsideRoot(folder.path) else {
        throw StowawayError.refusal("Stowaway needs access to your .cargo folder first.")
      }
      // Already a link to the drive, or a folder: either is fine as it is.
      if !isSymlink(folder.path), !isRealDirectory(folder.path) {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      }
      try editCargoConfig { try CargoBuildFolder.turningOn($0) }
      note("Cargo now builds into \(folder.path)")
    }
  }

  /// Removes Stowaway's line from Cargo's config. The build folder is left for the caller.
  public func turnOffCargoBuildFolder() throws {
    try exclusively {
      enterGrants()
      try editCargoConfig { CargoBuildFolder.turningOff($0) }
      note("Cargo builds into each project's target folder again")
    }
  }

  private func editCargoConfig(_ change: (String) throws -> String) throws {
    let file = CargoBuildFolder.configFile()
    let before: String
    if FileManager.default.fileExists(atPath: file.path) {
      before = try String(contentsOf: file, encoding: .utf8)
    } else {
      before = ""
    }
    let after = try change(before)
    guard after != before else { return }
    // A config that only had Stowaway's line goes with it.
    if after.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      try FileManager.default.removeItem(at: file)
    } else {
      try after.write(to: file, atomically: true, encoding: .utf8)
    }
  }
}

extension Engine {
  /// Deletes the shared build folder's per-project folders no build has used for `age`
  /// (30 days unless asked otherwise). Each project gets its own folder there, named after its
  /// path, so a deleted worktree's stays behind: nothing else ever removes it. A project that
  /// builds again after its folder went just builds from scratch.
  ///
  /// "Used" is the newest change to the project's folder, its profiles and what's directly in
  /// them (a build that compiles anything changes some of those). A project a build holds right
  /// now is never touched. While the drive is away the folder is a stand-in, and is left alone.
  /// Returns how many folders went, and their size.
  @discardableResult
  public func pruneCargoBuildFolder(
    _ folder: URL = CargoBuildFolder.folder, unusedFor age: TimeInterval = 30 * 86_400
  ) -> (folders: Int, bytes: Int64) {
    var result = (folders: 0, bytes: Int64(0))
    _ = try? exclusively {
      let store = enterGrants()
      guard isInsideRoot(folder.path) else { return }
      let entry = entries().first { $0.local == folder.path }
      if let entry, !entry.online { return }
      let cutoff = Date().addingTimeInterval(-age)
      // `<hash>/<hash>` per project, as `{workspace-path-hash}` lays them out.
      for group in subdirectories(of: folder) {
        for project in subdirectories(of: group) {
          guard !Self.cargoProjectIsBusy(project),
            Self.lastCargoUse(of: project) < cutoff
          else { continue }
          let bytes = Measure.allocatedSize(project.path)
          guard (try? trash(project)) != nil else { continue }
          result.folders += 1
          result.bytes += bytes
          // On the drive, the index's notes on its files go with it.
          if let entry, let store, let remote = try? storePath(entry.remote, in: store) {
            let relative = String(remote.path.dropFirst(store.path.count + 1))
            forgetShared(
              "\(relative)/\(group.lastPathComponent)/\(project.lastPathComponent)", store: store)
          }
        }
        // A group left empty goes too. (One still being erased in the background goes next
        // time.)
        if ((try? FileManager.default.contentsOfDirectory(atPath: group.path)) ?? ["?"]).isEmpty {
          rmdir(group.path)
        }
      }
      if result.folders > 0 {
        note(
          "deleted \(result.folders) unused projects' builds from Cargo's shared build folder (\(ByteCountFormatter.string(fromByteCount: result.bytes, countStyle: .file)))"
        )
      }
    }
    return result
  }

  /// When a project in the shared build folder was last built: the newest modification time of
  /// its folder, its profiles (and cross-compiled targets' profiles), and what they hold.
  static func lastCargoUse(of project: URL) -> Date {
    var newest = Date.distantPast
    func consider(_ path: String) {
      var st = stat()
      if lstat(path, &st) == 0 {
        newest = max(newest, Date(timeIntervalSince1970: TimeInterval(st.st_mtimespec.tv_sec)))
      }
    }
    consider(project.path)
    let fm = FileManager.default
    for level in [project] + subdirectories(of: project) {
      for child in (try? fm.contentsOfDirectory(atPath: level.path)) ?? [] {
        let path = level.path + "/" + child
        consider(path)
        if isRealDirectory(path) {
          for inner in ((try? fm.contentsOfDirectory(atPath: path)) ?? []).prefix(200) {
            consider(path + "/" + inner)
          }
        }
      }
    }
    return newest
  }

  /// Whether a build holds any of a project's profiles right now.
  static func cargoProjectIsBusy(_ project: URL) -> Bool {
    Measure.isBusy(Candidate(kind: .cargoTarget, path: project.path, project: nil))
  }
}
