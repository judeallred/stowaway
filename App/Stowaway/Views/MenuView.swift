import AppKit
import SwiftUI

/// The menu bar window: how much is stowed, the drive, what's happening, then a few actions.
/// Stowing is automatic, so there's nothing to stow by hand here.
struct MenuView: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      if model.freeStowageFull {
        fullNotice
      }
      headline
      storage
      status
      Divider()
      VStack(alignment: .leading, spacing: 2) {
        action("Open Stowaway…", "macwindow") { show { openWindow(id: WindowID.library) } }
        action("Settings…", "gearshape") { show { openSettings() } }
        action("Report a Bug…", "ladybug") {
          dismiss()
          NSWorkspace.shared.open(BugReport.url(model: model))
        }
        if !model.store.hasPurchased {
          action("Support Stowaway…", "heart") { openLibrary(showing: \.showingSupport) }
        }
        action("Help", "questionmark.circle", submenu: true) { showHelp() }
      }
      Divider()
      action("Quit Stowaway", "power") { NSApp.terminate(nil) }
    }
    .padding(14)
    .frame(width: 300)
  }

  /// How much is stowed, and how much more is on this Mac.
  private var headline: some View { StowedHeadline(model: model) }

  /// The drive and its space.
  @ViewBuilder private var storage: some View {
    if let name = model.driveName {
      VStack(alignment: .leading, spacing: 5) {
        Label(
          model.driveConnected ? name : "\(name) (disconnected)", systemImage: model.driveSymbol
        )
        .font(.callout)
        if model.driveConnected, let free = model.driveFreeBytes, let total = model.driveTotalBytes,
          total > 0
        {
          DriveSpaceBar(model: model, free: free, total: total)
          Text("\(Format.bytes(free)) free of \(Format.bytes(total))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
      }
    } else {
      action("Select Drive…", "externaldrive.badge.plus") { show { model.chooseDrive() } }
        .padding(.horizontal, -6)
    }
  }

  /// What's happening now, or what happens next.
  private var status: some View {
    StowStatus(model: model).font(.callout).foregroundStyle(.secondary)
  }

  /// At the very top when the free stowage is used up.
  private var fullNotice: some View {
    VStack(alignment: .leading, spacing: 4) {
      Label("Free stowage is full", systemImage: "exclamationmark.circle.fill")
        .font(.callout.weight(.semibold))
        .foregroundStyle(.orange)
      Text("New folders stay on this Mac until you go unlimited.")
        .font(.caption).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      Button("Go Unlimited…") { openLibrary(showing: \.showingSupport) }
        .buttonStyle(.link).font(.callout)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(10)
    .background(.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.orange.opacity(0.6)))
  }

  private func action(
    _ title: String, _ symbol: String, submenu: Bool = false, _ run: @escaping () -> Void
  ) -> some View {
    Button(action: run) {
      HStack {
        Label(title, systemImage: symbol)
        Spacer()
        if submenu { Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true) }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
  }

  /// Help's items in a native menu at the pointer, so the Help row itself looks like every
  /// other action (a SwiftUI Menu draws its title differently).
  private func showHelp() {
    let menu = NSMenu()
    for (title, url) in [
      ("Stowaway Website", Links.website), ("Get Help", Links.support),
      ("Privacy Policy", Links.privacyPolicy),
    ] {
      menu.addItem(ClosureMenuItem(title) { NSWorkspace.shared.open(url) })
    }
    menu.addItem(.separator())
    menu.addItem(
      ClosureMenuItem("Show Setup Again…") { openLibrary(showing: \.showingOnboarding) })
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  /// Opens the library window with one of its sheets showing.
  private func openLibrary(showing sheet: ReferenceWritableKeyPath<AppModel, Bool>) {
    show {
      openWindow(id: WindowID.library)
      model[keyPath: sheet] = true
    }
  }

  private func show(_ open: () -> Void) {
    dismiss()
    NSApp.activate()
    open()
  }
}

/// An NSMenuItem that runs a closure.
private final class ClosureMenuItem: NSMenuItem {
  private let run: () -> Void

  init(_ title: String, run: @escaping () -> Void) {
    self.run = run
    super.init(title: title, action: #selector(fire), keyEquivalent: "")
    target = self
  }

  required init(coder: NSCoder) { fatalError("not used") }

  @objc private func fire() { run() }
}
