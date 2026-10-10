import DiskArbitration
import Foundation
import ServiceManagement

enum Outcome: String, Sendable {
  case pass = "PASS"
  case fail = "FAIL"
  case skip = "SKIP"
  /// Informational: worth reading, not a yes/no.
  case info = "INFO"
}

struct ProbeResult: Identifiable, Sendable {
  let id = UUID()
  let group: String
  let name: String
  /// What Stowaway needs this for.
  let need: String
  let outcome: Outcome
  let detail: String
}

/// Runs every probe. Each one exercises something the Rust engine or the app does today, from
/// inside the App Sandbox.
struct ProbeRun {
  private(set) var results: [ProbeResult] = []
  private var group = ""

  static let agentPlist = "dev.stowaway.sandbox-probe.agent.plist"
  static let realHome: String = {
    guard let pw = getpwuid(getuid()), let dir = pw.pointee.pw_dir else { return "/Users/unknown" }
    return String(cString: dir)
  }()

  static func runAll() -> [ProbeResult] {
    var run = ProbeRun()
    run.sandbox()
    run.unaskedFiles()
    let code = Bookmarks.resolve(.codeRoot)
    let drive = Bookmarks.resolve(.drive)
    run.chosenFolders(code: code, drive: drive)
    run.diskImages(code: try? code?.get(), drive: try? drive?.get())
    run.diskArbitration(drive: try? drive?.get())
    run.tools(code: try? code?.get())
    run.background()
    for case .success(let place) in [code, drive].compactMap({ $0 }) {
      place.url.stopAccessingSecurityScopedResource()
    }
    return run.results
  }

  private mutating func record(_ name: String, _ need: String, _ outcome: Outcome, _ detail: String) {
    results.append(ProbeResult(group: group, name: name, need: need, outcome: outcome, detail: detail))
  }

  private mutating func record(_ name: String, _ need: String, _ shell: ShellResult) {
    record(name, need, shell.ok ? .pass : .fail, shell.summary)
  }

  // MARK: - Sandbox

  private mutating func sandbox() {
    group = "Sandbox"
    let container = ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"]
    record(
      "App Sandbox is on", "Required for every Mac App Store app (guideline 2.4.5(i))",
      container == nil ? .fail : .pass,
      "container=\(container ?? "none"), NSHomeDirectory=\(NSHomeDirectory())")
  }

  // MARK: - Files without asking

  private mutating func unaskedFiles() {
    group = "Files without asking"
    let home = Self.realHome
    let fm = FileManager.default
    func list(_ path: String) -> String {
      if !fm.fileExists(atPath: path) { return "missing" }
      do {
        return "readable (\(try fm.contentsOfDirectory(atPath: path).count) entries)"
      } catch {
        return "denied"
      }
    }
    let code = list("\(home)/code")
    record(
      "List ~/code", "The agent watches a root folder; today it reads it freely",
      code.hasPrefix("readable") ? .pass : .fail, code)

    let caches = [
      "~/.npm", "~/.cargo/registry", "~/Library/Developer/Xcode/DerivedData", "~/Library/pnpm/store",
      "~/.gradle/caches", "~/go/pkg/mod", "~/.cache/huggingface/hub",
    ]
    let states = caches.map { ($0, list($0.replacingOccurrences(of: "~", with: home))) }
    let readable = states.filter { $0.1.hasPrefix("readable") }.count
    let present = states.filter { $0.1 != "missing" }.count
    record(
      "Read global caches", "Global kinds (§3) live at fixed paths the user never picks",
      present == 0 ? .skip : (readable == present ? .pass : .fail),
      states.map { "\($0.0): \($0.1)" }.joined(separator: "; "))

    let volumes = list("/Volumes")
    record(
      "List /Volumes", "Noticing the drive come and go", volumes.hasPrefix("readable") ? .pass : .fail,
      volumes)
    let external = ((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? [])
      .map { "/Volumes/\($0)" }
      .filter { (try? fm.destinationOfSymbolicLink(atPath: $0)) == nil }
    if let first = external.first {
      let state = list(first)
      record(
        "List an external volume's root", "Finding the Stowaway folder on a drive the user didn't pick",
        state.hasPrefix("readable") ? .pass : .fail, "\(first): \(state)")
    }
  }

  // MARK: - Chosen folders

  private mutating func chosenFolders(
    code: Result<ResolvedPlace, any Error>?, drive: Result<ResolvedPlace, any Error>?
  ) {
    group = "Chosen folders (security-scoped bookmarks)"
    for (place, resolved) in [(Place.codeRoot, code), (.drive, drive)] {
      switch resolved {
      case nil:
        record(
          "\(place.title): resolve bookmark", "Reaching the folder after a relaunch", .skip,
          "not chosen yet")
      case .failure(let error):
        record(
          "\(place.title): resolve bookmark", "Reaching the folder after a relaunch", .fail,
          error.localizedDescription)
      case .success(let p):
        record(
          "\(place.title): resolve bookmark", "Reaching the folder after a relaunch",
          p.fromEarlierLaunch ? .pass : .info,
          "\(p.url.path)\(p.stale ? " (stale)" : "")"
            + (p.fromEarlierLaunch ? ", saved by an earlier launch" : ", saved this launch: relaunch to prove it persists"))
        mutate(in: p.url, place: place)
      }
    }
    if case .success(let p) = code { walk(p.url) }
  }

  private mutating func mutate(in root: URL, place: Place) {
    let fm = FileManager.default
    let dir = root.appendingPathComponent(".stowaway-sandbox-probe-\(UUID().uuidString.prefix(8))")
    do {
      try fm.createDirectory(at: dir, withIntermediateDirectories: false)
      let file = dir.appendingPathComponent("a")
      try Data("x".utf8).write(to: file)
      try fm.moveItem(at: file, to: dir.appendingPathComponent("b"))
      try fm.removeItem(at: dir)
      record(
        "\(place.title): create, rename, delete", "Moving folders between Mac and drive", .pass,
        "in \(root.path)")
    } catch {
      try? fm.removeItem(at: dir)
      record(
        "\(place.title): create, rename, delete", "Moving folders between Mac and drive", .fail,
        error.localizedDescription)
    }
  }

  /// Walks the code folder the way `scan` does, counting what Stowaway would adopt.
  private mutating func walk(_ root: URL) {
    let start = Date()
    var nodeModules = 0
    var cargoTargets = 0
    var denied = 0
    let fm = FileManager.default
    var stack: [(URL, Int)] = [(root, 0)]
    while let (dir, depth) = stack.popLast() {
      guard let entries = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey])
      else {
        denied += 1
        continue
      }
      for entry in entries {
        guard (try? entry.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
        switch entry.lastPathComponent {
        case "node_modules": nodeModules += 1
        case "target" where fm.fileExists(atPath: entry.appendingPathComponent("CACHEDIR.TAG").path):
          cargoTargets += 1
        case ".git", "target": break
        default: if depth < 4 { stack.append((entry, depth + 1)) }
        }
      }
    }
    record(
      "Code folder: scan", "Finding node_modules and target/ to adopt", denied == 0 ? .pass : .fail,
      "\(nodeModules) node_modules, \(cargoTargets) cargo targets, \(denied) unreadable folders, "
        + String(format: "%.1fs", Date().timeIntervalSince(start)))
  }

  // MARK: - Disk images

  private mutating func diskImages(code: ResolvedPlace?, drive: ResolvedPlace?) {
    group = "Disk images (the core mechanism, §4.1)"
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(
      "probe-\(UUID().uuidString.prefix(8))")
    try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    imageSuite(label: "in the container", imageDir: tmp, projectParent: tmp, viaDA: false)
    imageSuite(label: "in the container, mounted by DiskArbitration", imageDir: tmp, projectParent: tmp, viaDA: true)
    if let code, let drive {
      let imageDir = drive.url.appendingPathComponent(".stowaway-sandbox-probe")
      let projectParent = code.url.appendingPathComponent(".stowaway-sandbox-probe")
      imageSuite(label: "on the drive, mounted in the code folder", imageDir: imageDir, projectParent: projectParent, viaDA: false)
      imageSuite(label: "on the drive, mounted in the code folder by DiskArbitration", imageDir: imageDir, projectParent: projectParent, viaDA: true)
      try? FileManager.default.removeItem(at: imageDir)
      try? FileManager.default.removeItem(at: projectParent)
    } else {
      record(
        "Real layout: image on drive, mounted in code folder", "What Stowaway actually does", .skip,
        "choose both a code folder and a drive")
    }
  }

  /// Creates a sparse bundle, mounts it over a fresh `node_modules`, writes through it and
  /// detaches it, recording each step. Mirrors `hdiutil.rs`.
  private mutating func imageSuite(label: String, imageDir: URL, projectParent: URL, viaDA: Bool) {
    let fm = FileManager.default
    let image = imageDir.appendingPathComponent("probe-\(UUID().uuidString.prefix(8)).sparsebundle")
    let project = projectParent.appendingPathComponent("project-\(UUID().uuidString.prefix(8))")
    let mountPoint = project.appendingPathComponent("node_modules")
    defer {
      try? fm.removeItem(at: image)
      try? fm.removeItem(at: project)
    }
    do {
      try fm.createDirectory(at: imageDir, withIntermediateDirectories: true)
      try fm.createDirectory(at: mountPoint, withIntermediateDirectories: true)
      try Data("{}".utf8).write(to: project.appendingPathComponent("package.json"))
    } catch {
      record("\(label): set up", "", .fail, error.localizedDescription)
      return
    }

    let create = sh(
      "/usr/bin/hdiutil",
      ["create", "-type", "SPARSEBUNDLE", "-fs", "APFS", "-size", "200m", "-volname", "StowProbe", image.path])
    record("\(label): hdiutil create", "Making each entry's image", create)
    guard create.ok else { return }

    var device: String?
    if viaDA {
      let attach = sh("/usr/bin/hdiutil", ["attach", "-plist", "-nobrowse", "-noautoopen", "-nomount", image.path])
      record("\(label): hdiutil attach -nomount", "Attaching without mounting", attach)
      guard attach.ok, let entities = parsePlist(attach.out)?["system-entities"] as? [[String: Any]] else { return }
      device = wholeDisk(entities)
      let apfsVolume = entities.last { ($0["content-hint"] as? String) == "41504653-0000-11AA-AA11-00306543ECAC" }
      guard let bsd = (apfsVolume?["dev-entry"] as? String) else {
        record("\(label): find APFS volume", "", .fail, "entities: \(entities.map { $0["dev-entry"] ?? "?" })")
        if let device { _ = sh("/usr/bin/hdiutil", ["detach", "-force", device]) }
        return
      }
      let mounted = daMount(bsdName: bsd, at: mountPoint)
      record("\(label): DADiskMount at path", "Mounting in place without hdiutil -mountpoint", mounted == nil ? .pass : .fail, mounted ?? "mounted \(bsd) at \(mountPoint.path)")
    } else {
      let attach = sh(
        "/usr/bin/hdiutil",
        ["attach", "-plist", "-nobrowse", "-noautoopen", "-owners", "on", "-mountpoint", mountPoint.path, image.path])
      record("\(label): hdiutil attach -mountpoint", "Mounting the image in place over node_modules", attach)
      guard attach.ok else { return }
      device = (parsePlist(attach.out)?["system-entities"] as? [[String: Any]]).flatMap(wholeDisk)
    }
    defer {
      if let device {
        let detach = sh("/usr/bin/hdiutil", ["detach", "-quiet", device])
        record("\(label): hdiutil detach", "Ejecting cleanly", detach)
        if !detach.ok { _ = sh("/usr/bin/hdiutil", ["detach", "-force", device]) }
      }
    }

    let (onName, fsType) = mountInfo(mountPoint.path)
    let parentDev = (try? fm.attributesOfItem(atPath: project.path)[.systemNumber] as? Int) ?? -1
    let mountDev = (try? fm.attributesOfItem(atPath: mountPoint.path)[.systemNumber] as? Int) ?? -1
    let inPlace = onName == mountPoint.resolvingSymlinksInPath().path || onName == mountPoint.path
    record(
      "\(label): mounted in place", "Tools must see an ordinary folder at the usual path",
      inPlace && parentDev != mountDev ? .pass : .fail,
      "statfs mount-on=\(onName), fs=\(fsType), device differs from parent: \(parentDev != mountDev)")

    // Files a sandboxed process writes, the image's bands included, get com.apple.quarantine, and
    // a quarantined image mounts with MNT_QUARANTINE: nothing on it can execute (.bin scripts,
    // native addons, build scripts).
    var flags = statfs()
    let quarantined = statfs(mountPoint.path, &flags) == 0 && flags.f_flags & UInt32(MNT_QUARANTINE) != 0
    let imageTagged = getxattr(image.path, "com.apple.quarantine", nil, 0, 0, 0) >= 0
    record(
      "\(label): mount is executable", "node_modules/.bin, native addons and build scripts must run",
      quarantined ? .fail : .pass,
      "mount quarantine flag: \(quarantined), image has com.apple.quarantine: \(imageTagged)")

    let file = mountPoint.appendingPathComponent("left-pad/index.js")
    do {
      try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
      try Data("module.exports = 1".utf8).write(to: file)
      let back = try String(contentsOf: file, encoding: .utf8)
      record(
        "\(label): write through the mount", "The app moving data into the image",
        back == "module.exports = 1" ? .pass : .fail, "wrote and read \(file.lastPathComponent)")
    } catch {
      record("\(label): write through the mount", "The app moving data into the image", .fail, error.localizedDescription)
    }

    let info = sh("/usr/bin/hdiutil", ["info", "-plist"])
    let images = (parsePlist(info.out)?["images"] as? [[String: Any]]) ?? []
    let seen = images.contains { ($0["image-path"] as? String).map { $0.hasSuffix(image.lastPathComponent) } ?? false }
    record(
      "\(label): hdiutil info sees it", "Finding attached images after an agent restart",
      info.ok && seen ? .pass : .fail, info.ok ? "\(images.count) attached images listed" : info.summary)
  }

  private func wholeDisk(_ entities: [[String: Any]]) -> String? {
    entities.compactMap { $0["dev-entry"] as? String }
      .filter { !$0.dropFirst("/dev/disk".count).contains("s") }
      .first
  }

  private func mountInfo(_ path: String) -> (String, String) {
    var s = statfs()
    guard statfs(path, &s) == 0 else { return ("statfs failed: \(String(cString: strerror(errno)))", "?") }
    let on = withUnsafeBytes(of: &s.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    let type = withUnsafeBytes(of: &s.f_fstypename) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
    return (on, type)
  }

  /// Mounts `/dev/diskNsM` at `path` through DiskArbitration. Returns an error message, or nil.
  private func daMount(bsdName: String, at path: URL) -> String? {
    guard let session = DASessionCreate(kCFAllocatorDefault) else { return "DASessionCreate failed" }
    let queue = DispatchQueue(label: "da")
    DASessionSetDispatchQueue(session, queue)
    defer { DASessionSetDispatchQueue(session, nil) }
    let name = bsdName.replacingOccurrences(of: "/dev/", with: "")
    guard let disk = DADiskCreateFromBSDName(kCFAllocatorDefault, session, name) else {
      return "DADiskCreateFromBSDName(\(name)) failed"
    }
    final class Box: @unchecked Sendable {
      let done = DispatchSemaphore(value: 0)
      var error: String?
    }
    let box = Box()
    let context = Unmanaged.passRetained(box).toOpaque()
    DADiskMount(
      disk, path as CFURL, DADiskMountOptions(kDADiskMountOptionDefault),
      { _, dissenter, context in
        let box = Unmanaged<Box>.fromOpaque(context!).takeRetainedValue()
        if let dissenter {
          let status = DADissenterGetStatus(dissenter)
          let text = DADissenterGetStatusString(dissenter).map { $0 as String } ?? ""
          box.error = String(format: "dissented: 0x%08x %@", status, text)
        }
        box.done.signal()
      }, context)
    if box.done.wait(timeout: .now() + 30) == .timedOut { return "timed out" }
    return box.error
  }

  // MARK: - DiskArbitration

  private mutating func diskArbitration(drive: ResolvedPlace?) {
    group = "Drive identity"
    for path in ["/", drive?.url.path].compactMap({ $0 }) {
      if let desc = daDescription(path) {
        let pick = [
          kDADiskDescriptionVolumeKindKey, kDADiskDescriptionVolumeUUIDKey, kDADiskDescriptionDeviceInternalKey,
          kDADiskDescriptionDeviceProtocolKey, kDADiskDescriptionMediaRemovableKey,
        ].map { "\(($0 as String).replacingOccurrences(of: "DA", with: ""))=\(desc[$0 as String] ?? "nil")" }
        record("DiskArbitration describe \(path)", "Replacing `diskutil info` (format, UUID, internal?)", .pass, pick.joined(separator: ", "))
      } else {
        record("DiskArbitration describe \(path)", "Replacing `diskutil info` (format, UUID, internal?)", .fail, "no description")
      }
      record("diskutil info \(path)", "drive.rs: checking the drive is APFS", sh("/usr/sbin/diskutil", ["info", "-plist", path]))
    }
  }

  private func daDescription(_ path: String) -> [String: Any]? {
    guard let session = DASessionCreate(kCFAllocatorDefault),
      let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, URL(fileURLWithPath: path) as CFURL)
    else { return nil }
    return DADiskCopyDescription(disk) as? [String: Any]
  }

  // MARK: - Tools

  private mutating func tools(code: ResolvedPlace?) {
    group = "Command-line tools the engine runs"
    record("id -u", "launchd.rs: the gui/<uid> domain", sh("/usr/bin/id", ["-u"]))
    record("sw_vers", "Bug reports", sh("/usr/bin/sw_vers", ["-productVersion"]))
    let ioreg = sh("/usr/sbin/ioreg", ["-rd1", "-c", "IOPlatformExpertDevice"])
    record(
      "ioreg IOPlatformUUID", "engine.rs machine_id: telling Macs apart on a shared drive",
      ioreg.ok && ioreg.out.contains("IOPlatformUUID") ? .pass : .fail,
      ioreg.ok ? "found: \(ioreg.out.contains("IOPlatformUUID"))" : ioreg.summary)
    record("iostat -Id disk0", "diskload.rs: pacing copies around other disk activity", sh("/usr/sbin/iostat", ["-Id", "disk0"]))

    let lsof = sh("/usr/sbin/lsof", ["-nP", "-w", "-F", "pcn"], timeout: 120)
    let pids = Set(lsof.out.split(separator: "\n").filter { $0.hasPrefix("p") })
    record(
      "lsof sees other processes", "idle.rs: never move a folder another process has open",
      pids.count > 5 ? .pass : .fail,
      "\(pids.count) processes visible (\(lsof.launchError ?? "exit \(lsof.status)"))")

    record(
      "launchctl print gui/<uid>", "launchd.rs: installing and kicking the agent",
      sh("/bin/launchctl", ["print", "gui/\(getuid())/com.apple.Finder"]))
    record("osascript", "agent.rs: notifications", sh("/usr/bin/osascript", ["-e", "return 1"]))

    let git = sh("/usr/bin/git", ["--version"])
    record("git --version", "Skipping folders tracked by git", git)
    if let code {
      record(
        "git ls-files in code folder", "Skipping folders tracked by git",
        sh("/usr/bin/git", ["-C", code.url.path, "rev-parse", "--show-toplevel"]))
    }
    for node in ["/opt/homebrew/bin/node", "/usr/local/bin/node"] where FileManager.default.fileExists(atPath: node) {
      record("node --version", "kinds.rs: asking pnpm/go where their caches are", sh(node, ["--version"]))
      break
    }

    let cli = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/stowaway")
    if FileManager.default.isExecutableFile(atPath: cli.path) {
      record("Embedded stowaway --version", "Running the Rust engine as a sandboxed child", sh(cli.path, ["--version"]))
      let status = sh(cli.path, ["status"])
      record("Embedded stowaway status", "The engine finding its config and state", status.launchError == nil ? .info : .fail, status.summary)
    } else {
      record("Embedded stowaway", "Running the Rust engine as a sandboxed child", .skip, "not bundled (build it with bundle.sh)")
    }
  }

  // MARK: - Background

  private mutating func background() {
    group = "Running in the background"
    record(
      "Login item status (SMAppService.mainApp)", "Starting at login; allowed in the sandbox with user consent", .info,
      describe(SMAppService.mainApp.status))
    let agent = SMAppService.agent(plistName: Self.agentPlist)
    var detail = describe(agent.status)
    let heartbeat = "\(Self.realHome)/Library/Containers/dev.stowaway.sandbox-probe.agent/Data/heartbeat.txt"
    if let text = try? String(contentsOfFile: heartbeat, encoding: .utf8) {
      detail += "; heartbeat: \(text)"
    } else {
      detail += "; agent's heartbeat isn't readable from the app (separate containers): read it from Terminal"
    }
    record("Launch agent status (SMAppService.agent)", "The always-on agent", .info, detail)
  }

  private func describe(_ status: SMAppService.Status) -> String {
    switch status {
    case .notRegistered: "not registered"
    case .enabled: "enabled"
    case .requiresApproval: "requires approval in System Settings › Login Items"
    case .notFound: "not found in the bundle"
    @unknown default: "unknown (\(status.rawValue))"
    }
  }
}

enum Report {
  static func markdown(_ results: [ProbeResult]) -> String {
    var lines = ["# Stowaway sandbox probe", "", "Run \(Date().formatted()) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString)", ""]
    var group = ""
    for r in results {
      if r.group != group {
        group = r.group
        lines += ["", "## \(group)", "", "| | Probe | Detail |", "|---|---|---|"]
      }
      let detail = r.detail.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: " ")
      lines.append("| \(r.outcome.rawValue) | \(r.name) | \(detail) |")
    }
    return lines.joined(separator: "\n") + "\n"
  }
}
