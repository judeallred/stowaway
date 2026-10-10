import Foundation
import ServiceManagement

/// Starts the background agent: through `SMAppService` when running from the app bundle (the
/// agent's plist and binary ship inside it), otherwise via the `stowaway` CLI.
enum AgentLauncher {
  static let plistName = "dev.stowaway.agent.plist"

  static func start() throws {
    if Bundle.main.bundleURL.pathExtension == "app" {
      try SMAppService.agent(plistName: plistName).register()
      kickstart()
      return
    }
    guard let binary = cliPath() else {
      throw LaunchError.cliNotFound
    }
    let process = Process()
    process.executableURL = binary
    process.arguments = ["agent", "install"]
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 {
      throw LaunchError.failed(process.terminationStatus)
    }
  }

  /// Opens the menu bar app at login. Registers once, on the bundled app's first launch, so
  /// turning it off in System Settings → Login Items sticks. The agent starts at login on its
  /// own (`RunAtLoad`).
  static func registerLoginItem() {
    guard Bundle.main.bundleURL.pathExtension == "app" else { return }
    let key = "registeredLoginItem"
    guard !UserDefaults.standard.bool(forKey: key) else { return }
    do {
      try SMAppService.mainApp.register()
      UserDefaults.standard.set(true, forKey: key)
    } catch {
      NSLog("Stowaway: couldn't add the login item: \(error)")
    }
  }

  /// Starts the installed agent if it isn't running, e.g. after Quit Stowaway stopped it. The
  /// agent reattaches the images as it starts. Does nothing if no agent is installed.
  static func kickstart() {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
    process.arguments = ["kickstart", "gui/\(getuid())/dev.stowaway.agent"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
  }

  /// The `stowaway` CLI: bundled helper first, then common install locations.
  static func cliPath() -> URL? {
    if let bundled = Bundle.main.url(forAuxiliaryExecutable: "stowaway") {
      return bundled
    }
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    let candidates = [
      "\(home)/.cargo/bin/stowaway", "/opt/homebrew/bin/stowaway", "/usr/local/bin/stowaway",
    ]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
      .map { URL(fileURLWithPath: $0) }
  }

  enum LaunchError: LocalizedError {
    case cliNotFound
    case failed(Int32)

    var errorDescription: String? {
      switch self {
      case .cliNotFound:
        "Couldn't find the stowaway command. Install it, then run `stowaway init`."
      case .failed(let code):
        "Starting the agent failed (exit code \(code)). Try `stowaway agent install` in Terminal."
      }
    }
  }
}
