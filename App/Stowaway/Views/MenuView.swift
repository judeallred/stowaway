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
      if model.freeStowageFull {
        fullNotice
      }
      HStack(spacing: 8) {
        Image(nsImage: Logo.image(size: 22))
        Text("Stowaway").font(.headline)
        Spacer()
        if model.scanning { ProgressView().controlSize(.small) }
      }
      status
      Divider()
      VStack(alignment: .leading, spacing: 2) {
        action("Open Stowaway…", "macwindow") { show { openWindow(id: WindowID.library) } }
        let onMac = model.rows.filter { $0.place == .mac }
        if model.driveConnected, model.pendingBytes > 0 {
          // What's pending: Stow All skips folders that can't be stowed.
          action("Stow All (\(Format.bytes(model.pendingBytes)))", "shippingbox") {
            Task { await model.offload(onMac.filter { !model.isRefused($0) }) }
          }
          .disabled(model.activity != nil)
        } else if !model.driveConnected, !onMac.isEmpty {
          action("Purge All (\(Format.bytes(model.reclaimableBytes)))…", "trash") {
            show { confirmPurge(onMac) }
          }
          .disabled(model.activity != nil)
        }
      }
      Divider()
      VStack(alignment: .leading, spacing: 2) {
        action("Settings…", "gearshape") { show { openSettings() } }
        if !model.store.hasPurchased {
          action("Support Stowaway…", "heart") { openLibrary(showing: \.showingSupport) }
        }
        action("Help", "questionmark.circle", submenu: true) { showHelp() }
      }
      Divider()
      action("Quit Stowaway", "power") { NSApp.terminate(nil) }
    }
    .padding(12)
    .frame(width: 290)
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

  @ViewBuilder private var status: some View {
    VStack(alignment: .leading, spacing: 4) {
      if let name = model.driveName {
        Label(
          model.driveConnected ? "\(name) connected" : "\(name) disconnected",
          systemImage: model.driveSymbol)
        StowageSummary(model: model)
      } else {
        action("Select Drive…", "externaldrive.badge.plus") { show { model.chooseDrive() } }
          .padding(.horizontal, -6)
      }
      if let activity = model.activity {
        Text(activity).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
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
      ClosureMenuItem("Show Setup Again…") { openLibrary(showing: \.showingOnboarding) })
    menu.popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil)
  }

  /// Deletes every re-creatable folder on this Mac, after asking. Offered when there's no drive
  /// to stow them on.
  private func confirmPurge(_ rows: [Row]) {
    guard
      Panels.ask(
        "Delete \(Format.count(rows.count, "folder")) (\(Format.bytes(model.reclaimableBytes)))?",
        Panels.deleteNote + " Folders stowed on a drive aren't affected.",
        buttons: ["Delete"], destructive: [0]) != nil
    else { return }
    let model = model
    Task { await model.delete(rows) }
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
