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

    static func run(into folder: URL) async {
      // The project step as this Mac would see it on first launch: no folders chosen yet, and
      // suggestions from Spotlight.
      let fresh = AppModel()
      await fresh.detectProjectFolders()
      for (name, appearance) in [("light", NSAppearance.Name.aqua), ("dark", .darkAqua)] {
        NSApp.appearance = NSAppearance(named: appearance)
        renderAll(into: folder.appendingPathComponent(name))
        render(
          OnboardingView(model: fresh, step: .projects), "onboarding-1-this-mac", width: 560,
          height: 460, in: folder.appendingPathComponent(name))
        render(
          DashboardView(model: fresh), "library-no-drive", width: 1100, height: 300,
          in: folder.appendingPathComponent(name))
        render(
          MenuView(model: fresh), "menu-no-drive", width: 290, height: 360,
          in: folder.appendingPathComponent(name))
      }
      NSApp.appearance = NSAppearance(named: .aqua)
      renderAppStore(into: folder.appendingPathComponent("appstore"))
      NSApp.terminate(nil)
    }

    /// App Store screenshots: 1440×900 points rendered at 2× (2880×1800 pixels).
    private static func renderAppStore(into folder: URL) {
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let model = AppModel()
      model.loadDemo()
      let size = CGSize(width: 1440, height: 900)
      render(
        DashboardView(model: model), "1-library", width: size.width, height: size.height,
        in: folder,
        scale: 2)
      let shots: [(String, String, AnyView, CGSize)] = [
        (
          "2-menu", "Everything at a glance, from the menu bar", AnyView(MenuView(model: model)),
          CGSize(width: 290, height: 360)
        ),
        (
          "3-welcome", "Never touches your source code", AnyView(OnboardingView(model: model)),
          CGSize(width: 560, height: 460)
        ),
        (
          "4-support", "Stow 100 GB free. Then pay what you want.",
          AnyView(SupportView(model: model, store: model.store)), CGSize(width: 560, height: 700)
        ),
      ]
      for (name, caption, view, panel) in shots {
        let poster = Poster(caption: caption, panel: view, panelSize: panel)
        render(poster, name, width: size.width, height: size.height, in: folder, scale: 2)
      }
    }

    /// A screenshot backdrop: a caption over one of the app's windows, on the icon's gradient.
    private struct Poster: View {
      let caption: String
      let panel: AnyView
      let panelSize: CGSize
      /// 1.5×, or less for a tall panel, so it fits under the caption.
      var scale: CGFloat { min(1.5, 700 / panelSize.height) }

      var body: some View {
        ZStack {
          LinearGradient(
            colors: [
              Color(red: 0.05, green: 0.42, blue: 0.52), Color(red: 0.07, green: 0.13, blue: 0.27),
            ],
            startPoint: .top, endPoint: .bottom)
          VStack(spacing: 40) {
            Text(caption).font(.system(size: 52, weight: .bold)).foregroundStyle(.white)
            panel
              .frame(width: panelSize.width, height: panelSize.height)
              .background(Color(nsColor: .windowBackgroundColor))
              .clipShape(RoundedRectangle(cornerRadius: 12))
              .shadow(radius: 30, y: 12)
              .scaleEffect(scale)
              .frame(width: panelSize.width * scale, height: panelSize.height * scale)
          }
        }
      }
    }

    private static func renderAll(into folder: URL) {
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let model = AppModel()
      model.loadDemo()
      render(DashboardView(model: model), "library", width: 900, height: 560, in: folder)
      render(FoldersView(model: model), "folders", width: 1100, height: 600, in: folder)
      render(MenuView(model: model), "menu", width: 290, height: 360, in: folder)
      for step in OnboardingView.Step.allCases {
        render(
          OnboardingView(model: model, step: step), "onboarding-\(step.rawValue)", width: 560,
          height: 460, in: folder)
      }
      render(
        OnboardingView(model: model, step: .caches, explainingHomeFolder: true),
        "onboarding-2-home-folder", width: 560, height: 460, in: folder)
      render(
        SupportView(model: model, store: model.store), "support", width: 560, height: 720,
        in: folder)
      render(SettingsView(model: model), "settings", width: 520, height: 380, in: folder)
      render(
        SupportView(model: model, store: model.store, audience: .business), "support-business",
        width: 560, height: 720, in: folder)
      let paid = AppModel()
      paid.loadDemo()
      paid.store.setDemoOwned(["com.brooklynspaceport.stowaway.personal.2"])
      render(DashboardView(model: paid), "library-purchased", width: 1100, height: 300, in: folder)
      render(
        SupportView(model: paid, store: paid.store), "support-thanks", width: 560, height: 420,
        in: folder)
      render(BossLetterView(model: model), "expense-letter", width: 560, height: 520, in: folder)
      render(
        InvoiceView(model: model), "expense-invoice-preview", width: 560, height: 760, in: folder)
      render(
        InvoicePage(
          invoice: Invoice(
            status: .paid,
            item: "Stowaway for Mac: Growing Company. One-time purchase, unlimited stowing.",
            amount: "$149.99", date: .now, number: "SW-2000000812345678",
            billTo: "Sam Rivera\nNorthwind Labs",
            payment: "Paid through the Mac App Store (transaction 2000000812345678).")),
        "expense-invoice-paid", width: 612, height: 792, in: folder)
      render(StowSettings(model: model), "settings-stow", width: 520, height: 570, in: folder)
      render(GeneralSettings(model: model), "settings-general", width: 520, height: 520, in: folder)
      render(
        FoldersSidebar(model: model, scope: .constant(.all)), "folders-sidebar", width: 260,
        height: 600, in: folder)
    }

    private static func render(
      _ view: some View, _ name: String, width: CGFloat, height: CGFloat, in folder: URL,
      scale: CGFloat = 1
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
      guard
        let rep = NSBitmapImageRep(
          bitmapDataPlanes: nil, pixelsWide: Int(width * scale), pixelsHigh: Int(height * scale),
          bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
          colorSpaceName: .deviceRGB,
          bytesPerRow: 0, bitsPerPixel: 0)
      else { return }
      rep.size = NSSize(width: width, height: height)
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
      rows = [
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
      applyDemo(
        drive: "/Volumes/Archive SSD",
        roots: [
          "\(home)/code", "\(home)/.cargo", "\(home)/.gradle", "\(home)/.gradle/wrapper",
          "\(home)/code/work",
        ])
    }
  }
#endif
