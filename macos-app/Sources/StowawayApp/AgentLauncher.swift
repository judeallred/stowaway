import Foundation
import ServiceManagement

/// Starts the background agent: through `SMAppService` when running from the app bundle (the
/// agent's plist and binary ship inside it), otherwise via the `stowaway` CLI.
enum AgentLauncher {
  static let plistName = "dev.stowaway.agent.plist"

  static func start() throws {
    if Bundle.main.bundleURL.pathExtension == "app" {
      try SMAppService.agent(plistName: plistName).register()
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
