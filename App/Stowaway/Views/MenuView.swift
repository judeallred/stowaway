import AppKit
import SwiftUI

/// The menu bar window: status at a glance, then a single column of actions grouped by
/// dividers, with rarely used items in a Help menu.
struct MenuView: View {
  let model: AppModel
  @Environment(\.openWindow) private var openWindow
  @Environment(\.openSettings) private var openSettings
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      HStack(spacing: 8) {
        Image(nsImage: Logo.image(size: 22))
        Text("Stowaway").font(.headline)
        Spacer()
        if model.scanning { ProgressView().controlSize(.small) }
      }
      status
      Divider()
      VStack(alignment: .leading, spacing: 2) {
        action("Open Stowaway…", "macwindow") { show { openWindow(id: "library") } }
        action("Scan Now", "arrow.clockwise") { Task { await model.scan() } }
      }
      Divider()
      VStack(alignment: .leading, spacing: 2) {
        action("Settings…", "gearshape") { show { openSettings() } }
        if !model.store.hasPurchased {
          action("Support Stowaway…", "heart") {
            show {
              openWindow(id: "library")
              model.showingSupport = true
            }
          }
        }
        action("Help", "questionmark.circle", submenu: true) { showHelp() }
      }
      Divider()
      action("Quit Stowaway", "power") { NSApp.terminate(nil) }
    }
    .padding(12)
    .frame(width: 290)
  }

  @ViewBuilder private var status: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let name = model.driveName {
        Label(
          model.driveConnected ? "\(name) connected" : "\(name) disconnected",
          systemImage: model.driveConnected ? "externaldrive.fill" : "externaldrive.badge.xmark")
        Text("\(Format.bytes(model.offloadedBytes)) stowed")
          .foregroundStyle(.secondary)
      } else {
        Label("No drive chosen yet", systemImage: "externaldrive")
          .foregroundStyle(.secondary)
      }
      if model.reclaimableBytes > 0 {
        Text("\(Format.bytes(model.reclaimableBytes)) re-creatable on this Mac")
          .foregroundStyle(.secondary)
      }
    }
    .font(.callout)
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
    let model = model
    for (title, url) in [
      ("Stowaway Website", Links.website), ("Get Help", Links.support),
      ("Report a Bug…", BugReport.url(model: model)), ("Privacy Policy", Links.privacyPolicy),
    ] {
      menu.addItem(ClosureMenuItem(title) { NSWorkspace.shared.open(url) })
    }
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
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
