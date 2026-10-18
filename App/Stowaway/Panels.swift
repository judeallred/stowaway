import AppKit

/// The app's modal panels: choosing a folder and asking before something drastic.
@MainActor
enum Panels {
  /// An open panel for one folder. Nil if the user cancelled.
  static func chooseFolder(_ prompt: String, at directory: URL?) -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.canCreateDirectories = true
    panel.showsHiddenFiles = true
    panel.message = prompt
    panel.prompt = "Choose"
    panel.directoryURL = directory
    NSApp.activate()
    return panel.runModal() == .OK ? panel.url : nil
  }

  /// A warning with buttons (the last is Cancel). Returns the index of the button clicked, or
  /// nil for Cancel. `destructive` marks buttons that delete or forget something.
  static func ask(
    _ title: String, _ detail: String, buttons: [String], destructive: Set<Int> = []
  ) -> Int? {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText = title
    alert.informativeText = detail
    for (i, label) in buttons.enumerated() {
      alert.addButton(withTitle: label).hasDestructiveAction = destructive.contains(i)
    }
    alert.addButton(withTitle: "Cancel")
    NSApp.activate()
    let index =
      alert.runModal().rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
    return index < buttons.count ? index : nil
  }

  /// Why deleting is fine, shown before deleting folders on this Mac.
  static let deleteNote =
    "These are re-created by your tools (npm install, cargo build, Xcode…), which takes time and may need the network."
}
