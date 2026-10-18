import Foundation

/// A kind of re-creatable folder Stowaway knows how to find, clean and offload.
public enum Kind: String, CaseIterable, Codable, Sendable, Identifiable {
  case node
  case cargoTarget = "cargo-target"
  case next
  case venv
  case pnpmStore = "pnpm-store"
  case cargoHome = "cargo-home"
  case xcodeDerivedData = "xcode-derived-data"
  case gradleHome = "gradle-home"
  case go
  case jsCaches = "js-caches"
  case npx
  case huggingface

  public var id: String { rawValue }

  public var label: String {
    switch self {
    case .node: "node_modules"
    case .cargoTarget: "Cargo build files"
    case .next: "Next.js build files"
    case .venv: "Python virtualenv"
    case .pnpmStore: "pnpm store"
    case .cargoHome: "Cargo registry"
    case .xcodeDerivedData: "Xcode DerivedData"
    case .gradleHome: "Gradle caches"
    case .go: "Go caches"
    case .jsCaches: "npm, Yarn and bun caches"
    case .npx: "npx packages"
    case .huggingface: "Hugging Face models"
    }
  }

  public var summary: String {
    switch self {
    case .node: "A project's installed packages. npm, Yarn or bun reinstalls them."
    case .cargoTarget:
      "Compiled dependencies and caches from a Cargo build. The programs it builds stay on this Mac."
    case .next: "A Next.js project's build output and build cache."
    case .venv: "A Python project's virtual environment and installed packages."
    case .pnpmStore: "Packages pnpm shares between all your projects."
    case .cargoHome: "Crates and git dependencies Cargo has downloaded."
    case .xcodeDerivedData: "Xcode's build intermediates and indexes. Built apps stay on this Mac."
    case .gradleHome: "Downloaded dependencies and Gradle versions."
    case .go: "Downloaded modules and Go's build cache."
    case .jsCaches: "Download caches for npm, Yarn and bun."
    case .npx: "Packages npx has downloaded to run."
    case .huggingface: "Models and datasets downloaded from Hugging Face."
    }
  }

  /// How a project-scoped kind is recognised: a folder named `folderName` next to `manifest`.
  public struct ProjectRule: Sendable {
    public let folderName: String
    public let manifest: String
    /// A file that must be inside the folder (Cargo's `CACHEDIR.TAG`, a venv's `pyvenv.cfg`).
    public let requiredMarker: String?
  }

  /// Set for kinds that live in projects; nil for machine-wide caches.
  public var projectRule: ProjectRule? {
    switch self {
    case .node:
      ProjectRule(folderName: "node_modules", manifest: "package.json", requiredMarker: nil)
    case .cargoTarget:
      ProjectRule(folderName: "target", manifest: "Cargo.toml", requiredMarker: "CACHEDIR.TAG")
    case .next: ProjectRule(folderName: ".next", manifest: "package.json", requiredMarker: nil)
    case .venv:
      ProjectRule(folderName: ".venv", manifest: "pyproject.toml", requiredMarker: "pyvenv.cfg")
    default: nil
    }
  }

  public var isGlobal: Bool { projectRule == nil }

  /// Default locations of a machine-wide cache, relative to the home folder. A sandboxed app can't
  /// ask the tools (`pnpm store path`, `go env`) or read the shell's environment, so custom
  /// locations are added by the user instead.
  public var defaultLocations: [String] {
    switch self {
    case .pnpmStore: ["Library/pnpm/store"]
    case .cargoHome: [".cargo/registry", ".cargo/git"]
    case .xcodeDerivedData: ["Library/Developer/Xcode/DerivedData"]
    case .gradleHome: [".gradle/caches", ".gradle/wrapper/dists"]
    case .go: ["go/pkg/mod", "Library/Caches/go-build"]
    case .jsCaches:
      [".npm/_cacache", "Library/Caches/Yarn", ".yarn/berry/cache", ".bun/install/cache"]
    case .npx: [".npm/_npx"]
    case .huggingface: [".cache/huggingface/hub"]
    default: []
    }
  }

  /// The parts of a container worth moving: a Cargo `target/`'s build folders (the programs it
  /// builds stay on the Mac, so they run without the drive) and `DerivedData`'s intermediates
  /// (built apps stay local). Nil for kinds managed as one folder.
  public func parts(of container: URL) -> [URL]? {
    switch self {
    case .cargoTarget:
      // Profiles are `debug`, `release` and custom ones, plus `<triple>/<profile>` when
      // cross-compiling.
      var profiles: [URL] = []
      for dir in subdirectories(of: container) {
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("deps").path) {
          profiles.append(dir)
        } else {
          profiles += subdirectories(of: dir).filter {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("deps").path)
          }
        }
      }
      return profiles.flatMap { existing(["deps", "incremental", "build"], in: $0) }
    case .xcodeDerivedData:
      var parts = existing(["ModuleCache.noindex"], in: container)
      for project in subdirectories(of: container)
      where project.lastPathComponent != "ModuleCache.noindex" {
        parts += existing(
          ["Build/Intermediates.noindex", "Index.noindex", "SourcePackages"], in: project)
      }
      return parts
    default:
      return nil
    }
  }

  /// The kind a folder name belongs to in a project, if any.
  static func forFolderName(_ name: String) -> Kind? {
    allCases.first { $0.projectRule?.folderName == name }
  }
}

/// Real (non-symlink), non-hidden subfolders.
func subdirectories(of dir: URL) -> [URL] {
  ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
    .filter { !$0.hasPrefix(".") }
    .sorted()
    .map { dir.appendingPathComponent($0) }
    .filter { isRealDirectory($0.path) }
}

private func existing(_ names: [String], in dir: URL) -> [URL] {
  names.map { dir.appendingPathComponent($0) }.filter { isRealDirectory($0.path) }
}

/// Whether `path` is a folder and not a symlink to one.
func isRealDirectory(_ path: String) -> Bool {
  var st = stat()
  return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
}

/// `path` with every symlink resolved (so `/var/…` and `/private/var/…` compare equal). For a
/// path that doesn't exist yet, its deepest existing ancestor is resolved and the rest appended.
func canonicalPath(_ path: String) -> String {
  var head = path
  var tail: [String] = []
  while head != "/" && !head.isEmpty {
    if let resolved = realpath(head, nil) {
      defer { free(resolved) }
      return ([String(cString: resolved)] + tail.reversed()).joined(separator: "/")
    }
    tail.append((head as NSString).lastPathComponent)
    head = (head as NSString).deletingLastPathComponent
  }
  return path
}

/// Whether `path` is strictly inside `base`, comparing canonical paths.
func isInside(_ path: String, _ base: String) -> Bool {
  let base = canonicalPath(base)
  return canonicalPath(path).hasPrefix(base.hasSuffix("/") ? base : base + "/")
}

/// Whether `path` is a symlink.
func isSymlink(_ path: String) -> Bool {
  var st = stat()
  return lstat(path, &st) == 0 && st.st_mode & S_IFMT == S_IFLNK
}

/// The user's real home folder. Inside the sandbox `NSHomeDirectory()` is the app's container.
public let realHomeDirectory: URL = {
  if let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir {
    return URL(fileURLWithPath: String(cString: dir), isDirectory: true)
  }
  return FileManager.default.homeDirectoryForCurrentUser
}()
