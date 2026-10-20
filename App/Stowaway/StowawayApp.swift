import AppKit
import SwiftUI

/// Window identifiers.
enum WindowID {
  static let library = "library"
  static let folders = "folders"
}

@main
struct StowawayApp: App {
  @State private var model = AppModel()
  @NSApplicationDelegateAdaptor private var delegate: AppDelegate

  var body: some Scene {
    MenuBarExtra {
      MenuView(model: model)
    } label: {
      MenuBarLabel(model: model)
    }
    .menuBarExtraStyle(.window)

    Window("Stowaway", id: WindowID.library) {
      DashboardView(model: model)
        .frame(minWidth: 760, minHeight: 440)
        .sheet(isPresented: $model.showingOnboarding) { OnboardingView(model: model) }
        .sheet(isPresented: $model.showingSupport) { SupportView(model: model, store: model.store) }
    }
    .defaultSize(width: 860, height: 560)

    Window("Folders", id: WindowID.folders) {
      FoldersView(model: model)
        .frame(minWidth: 760, minHeight: 400)
    }
    .defaultSize(width: 920, height: 600)

    Settings {
      SettingsView(model: model)
    }
  }
}

/// Receives folders dropped on Stowaway's icon or opened with it ("Open With → Stowaway").
/// macOS grants access to them the same way as choosing them in an open panel.
final class AppDelegate: NSObject, NSApplicationDelegate {
  @MainActor static var model: AppModel?

  func application(_ application: NSApplication, open urls: [URL]) {
    MainActor.assumeIsolated {
      Self.model?.open(urls)
    }
  }

  /// Opening Stowaway again (from Finder, Spotlight or Launchpad) brings the window back: it has
  /// no Dock icon, and its menu bar icon may be hidden.
  func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
    MainActor.assumeIsolated {
      Self.model?.openLibrary?()
      NSApp.activate()
    }
    return true
  }
}

/// The menu bar icon. It's the first view to appear, so it starts the model and, on first
/// launch, opens the library window (a menu bar app has no Dock icon to click).
private struct MenuBarLabel: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    Image(nsImage: MenuBarImage.image(badge: model.iconState.badge))
      .accessibilityLabel(model.iconState.description)
      .task {
        guard !model.started else { return }
        model.started = true
        AppDelegate.model = model
        model.openLibrary = { openWindow(id: WindowID.library) }
        #if DEBUG
          if let folder = Snapshots.folder {
            await Snapshots.run(into: folder)
            return
          }
        #endif
        model.start()
        if model.showingOnboarding {
          openWindow(id: WindowID.library)
          NSApp.activate()
        }
      }
  }
}
