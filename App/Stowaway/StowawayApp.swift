import AppKit
import SwiftUI

@main
struct StowawayApp: App {
  @State private var model = AppModel()

  var body: some Scene {
    MenuBarExtra {
      MenuView(model: model)
    } label: {
      MenuBarLabel(model: model)
    }
    .menuBarExtraStyle(.window)

    Window("Stowaway", id: "library") {
      LibraryView(model: model)
        .frame(minWidth: 760, minHeight: 440)
        .sheet(isPresented: $model.showingOnboarding) { OnboardingView(model: model) }
        .sheet(isPresented: $model.showingSupport) { SupportView(model: model, store: model.store) }
    }
    .defaultSize(width: 920, height: 600)

    Settings {
      SettingsView(model: model)
    }
  }
}

/// The menu bar icon. It's the first view to appear, so it starts the model and, on first
/// launch, opens the library window (a menu bar app has no Dock icon to click).
private struct MenuBarLabel: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Image(nsImage: MenuBarImage.image(badge: model.badge))
      .accessibilityLabel(model.badgeDescription)
      .task {
        guard !model.started else { return }
        model.started = true
        #if DEBUG
          if let folder = Snapshots.folder {
            Snapshots.run(into: folder)
            return
          }
        #endif
        model.start()
        if model.showingOnboarding {
          openWindow(id: "library")
          NSApp.activate()
        }
      }
  }
}

extension AppModel {
  /// A small badge on the menu bar icon when something needs attention.
  var badge: String? {
    if !rows.filter({ $0.place == .driveAway }).isEmpty { return "exclamationmark" }
    return nil
  }

  var badgeDescription: String {
    badge == nil ? "Stowaway" : "Stowaway: the offload drive is disconnected"
  }
}
