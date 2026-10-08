import AppKit
import StowawayKit
import SwiftUI

@main
struct StowawayApp: App {
  private let model = AppModel()

  init() {
    // Running unbundled (`swift run`) still behaves like a menu bar app with no Dock icon.
    NSApplication.shared.setActivationPolicy(.accessory)
    AgentLauncher.kickstart()
    // Connect right away: the menu bar label's `.task` doesn't run until it's first rendered.
    model.start()
  }

  var body: some Scene {
    MenuBarExtra {
      PopoverView(model: model)
    } label: {
      MenuBarIcon(model: model)
    }
    .menuBarExtraStyle(.window)

    Window("Configure Folders", id: WindowID.folders) {
      ConfigureFoldersView(model: model)
    }
    .windowResizability(.contentSize)
  }
}

enum WindowID {
  static let folders = "folders"
}
