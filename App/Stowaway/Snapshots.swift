#if DEBUG
  import AppKit
  import StowawayCore
  import SwiftUI

  /// Debug builds only (App/scripts/check-release.sh verifies none of this ships): renders the
  /// app's screens with demo data to PNGs, for checking layouts and making App Store screenshots.
  ///
  ///   STOWAWAY_SNAPSHOTS=/path/to/folder Stowaway.app/Contents/MacOS/Stowaway
  @MainActor
  enum Snapshots {
    static var folder: URL? {
      ProcessInfo.processInfo.environment["STOWAWAY_SNAPSHOTS"].map { URL(fileURLWithPath: $0) }
    }

    static func run(into folder: URL) {
      for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        NSApp.appearance = NSAppearance(named: appearance)
        renderAll(into: folder.appendingPathComponent(name))
      }
      NSApp.terminate(nil)
    }

    private static func renderAll(into folder: URL) {
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let model = AppModel()
      model.loadDemo()
      render(LibraryView(model: model), "library", width: 1100, height: 680, in: folder)
      render(MenuView(model: model), "menu", width: 290, height: 360, in: folder)
      for step in OnboardingView.Step.allCases {
        render(
          OnboardingView(model: model, step: step), "onboarding-\(step.rawValue)", width: 520,
          height: 420, in: folder)
      }
      render(
        SupportView(model: model, store: model.store), "support", width: 520, height: 420,
        in: folder)
      render(SettingsView(model: model), "settings", width: 520, height: 380, in: folder)
    }

    private static func render(
      _ view: some View, _ name: String, width: CGFloat, height: CGFloat, in folder: URL
    ) {
      let hosting = NSHostingView(
        rootView: view.frame(width: width, height: height).background(
          Color(nsColor: .windowBackgroundColor)))
      let window = NSWindow(
        contentRect: NSRect(x: 0, y: 0, width: width, height: height), styleMask: [.titled],
        backing: .buffered,
        defer: false)
      window.contentView = hosting
      hosting.layoutSubtreeIfNeeded()
      // Let SwiftUI lay out and AppKit-backed controls draw.
      RunLoop.main.run(until: Date().addingTimeInterval(0.6))
      guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { return }
      hosting.cacheDisplay(in: hosting.bounds, to: rep)
      try? rep.representation(using: .png, properties: [:])?.write(
        to: folder.appendingPathComponent("\(name).png"))
      window.close()
    }
  }

  extension AppModel {
    /// Plausible folders for snapshots.
    func loadDemo() {
      let home = realHomeDirectory.path
      func row(
        _ kind: Kind, _ project: String?, _ folder: String, _ gb: Double, _ daysAgo: Double,
        _ place: Row.Place
      )
        -> Row
      {
        let base = project.map { "\(home)/code/\($0)" }
        var r = Row(
          kind: kind, path: base.map { "\($0)/\(folder)" } ?? "\(home)/\(folder)", project: base,
          place: place)
        let bytes = Int64(gb * 1_000_000_000)
        if place == .mac { r.localBytes = bytes } else { r.driveBytes = bytes }
        r.lastActivity = Date().addingTimeInterval(-daysAgo * 86_400)
        if place != .mac { r.entryPaths = [r.path] }
        return r
      }
      demoRows = [
        row(.node, "storefront-web", "node_modules", 1.21, 0.2, .mac),
        row(.cargoTarget, "telemetry-agent", "target", 14.8, 3, .drive),
        row(.node, "design-system", "node_modules", 0.84, 41, .drive),
        row(.next, "storefront-web", ".next", 0.62, 0.2, .mac),
        row(.venv, "ml-experiments", ".venv", 5.4, 12, .drive),
        row(.node, "marketing-site", "node_modules", 0.57, 96, .mac),
        row(.xcodeDerivedData, nil, "Library/Developer/Xcode/DerivedData", 38.2, 1, .drive),
        row(.cargoHome, nil, ".cargo/registry", 4.1, 2, .mac),
        row(.huggingface, nil, ".cache/huggingface/hub", 22.9, 9, .drive),
        row(.pnpmStore, nil, "Library/pnpm/store", 6.3, 5, .mac),
      ]
      applyDemo(drive: "/Volumes/Archive SSD", roots: ["\(home)/code", "\(home)/.cargo"])
    }
  }
#endif
