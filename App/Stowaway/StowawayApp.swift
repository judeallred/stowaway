import AppKit
import SwiftUI

/// Window identifiers.
enum WindowID {
  static let library = "library"
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

extension AppModel {
  /// What the menu bar icon shows: the plain logo when all is well, or a small badge for
  /// what's happening now or what needs attention. Problems outrank work in progress.
  enum IconState {
    case idle, scanning, stowing, bringingBack, deleting, testing, disconnected, warning, error

    /// The SF Symbol on the logo's corner, nil for the plain logo. Badges never animate.
    var badge: String? {
      switch self {
      case .idle: nil
      case .scanning: "magnifyingglass"
      case .stowing: "arrow.down"
      case .bringingBack: "arrow.uturn.backward"
      case .deleting: "trash.fill"
      case .testing: "speedometer"
      case .disconnected: "xmark.circle.fill"
      case .warning: "exclamationmark.circle.fill"
      case .error: "exclamationmark.triangle.fill"
      }
    }

    /// Spoken by VoiceOver.
    var description: String {
      switch self {
      case .idle: "Stowaway"
      case .scanning: "Stowaway, scanning folders"
      case .stowing: "Stowaway, stowing folders on the drive"
      case .bringingBack: "Stowaway, bringing folders back"
      case .deleting: "Stowaway, deleting folders"
      case .testing: "Stowaway, testing the drive"
      case .disconnected: "Stowaway, drive disconnected"
      case .warning: "Stowaway, needs attention"
      case .error: "Stowaway, problem"
      }
    }
  }

  var iconState: IconState {
    if message != nil { return .error }
    if driveName != nil && !driveConnected { return .disconnected }
    switch operation {
    case .stowing: return .stowing
    case .bringingBack: return .bringingBack
    case .deleting: return .deleting
    case .testing: return .testing
    case .scanning: return .scanning
    case nil: break
    }
    if needsAttention { return .warning }
    return .idle
  }

  /// The drive is nearly full (under 5% or 10 GB free), or the free stowage is used up while
  /// there's more waiting to be stowed.
  private var needsAttention: Bool {
    if driveConnected, let free = driveFreeBytes, let total = driveTotalBytes, total > 0,
      free < max(10_000_000_000, total / 20)
    {
      return true
    }
    if freeAllowanceLeft == 0 && rows.contains(where: { $0.place == .mac })
      && autoOffloadMinutes != 0
    {
      return true
    }
    return false
  }
}
