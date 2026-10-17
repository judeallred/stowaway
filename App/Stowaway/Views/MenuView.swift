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
        let onMac = model.rows.filter { $0.place == .mac }
        if !onMac.isEmpty {
          let size = Format.bytes(model.reclaimableBytes)
          if model.driveConnected {
            action("Stow All (\(size))", "shippingbox") { Task { await model.offload(onMac) } }
              .disabled(model.activity != nil)
          } else {
            action("Purge All (\(size))…", "trash") { show { confirmPurge(onMac) } }
              .disabled(model.activity != nil)
          }
        }
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
        Text(
          model.pendingBytes > 0
            ? "\(Format.bytes(model.offloadedBytes)) stowed · \(Format.bytes(model.pendingBytes)) pending"
            : "\(Format.bytes(model.offloadedBytes)) stowed"
        )
        .foregroundStyle(.secondary)
      } else {
        action("Select Drive…", "externaldrive.badge.plus") { show { model.chooseDrive() } }
          .padding(.horizontal, -6)
      }
      if let days = model.store.trialDaysLeft {
        Text("Free trial: \(days) day\(days == 1 ? "" : "s") left").foregroundStyle(.secondary)
      }
      if let activity = model.activity {
        Text(activity).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
      } else if model.reclaimableBytes > 0 {
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
    menu.addItem(.separator())
    menu.addItem(
      ClosureMenuItem("Show Setup Again…") {
        show {
          openWindow(id: "library")
          model.showingOnboarding = true
        }
      })
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  /// Deletes every re-creatable folder on this Mac, after asking. Offered when there's no drive
  /// to stow them on.
  private func confirmPurge(_ rows: [Row]) {
    let alert = NSAlert()
    alert.alertStyle = .warning
    alert.messageText =
      "Delete \(rows.count) folder\(rows.count == 1 ? "" : "s") (\(Format.bytes(model.reclaimableBytes)))?"
    alert.informativeText =
      "These are re-created by your tools (npm install, cargo build, Xcode…), which takes time and may need the network. Folders stowed on a drive aren't affected."
    alert.addButton(withTitle: "Delete")
    alert.addButton(withTitle: "Cancel")
    alert.buttons[0].hasDestructiveAction = true
    guard alert.runModal() == .alertFirstButtonReturn else { return }
    let model = model
    Task { await model.delete(rows) }
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
