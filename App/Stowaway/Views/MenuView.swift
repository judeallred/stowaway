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
        Menu {
          Button("Stowaway Website") { NSWorkspace.shared.open(Links.website) }
          Button("Get Help") { NSWorkspace.shared.open(Links.support) }
          Button("Report a Bug…") { NSWorkspace.shared.open(BugReport.url(model: model)) }
          Button("Privacy Policy") { NSWorkspace.shared.open(Links.privacyPolicy) }
        } label: {
          Label("Help", systemImage: "questionmark.circle")
        }
        .menuStyle(.borderlessButton)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
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
        Text("\(Format.bytes(model.offloadedBytes)) offloaded")
          .foregroundStyle(.secondary)
      } else {
        Label("No offload location yet", systemImage: "externaldrive")
          .foregroundStyle(.secondary)
      }
      if model.reclaimableBytes > 0 {
        Text("\(Format.bytes(model.reclaimableBytes)) re-creatable on this Mac")
          .foregroundStyle(.secondary)
      }
    }
    .font(.callout)
  }

  private func action(_ title: String, _ symbol: String, _ run: @escaping () -> Void) -> some View {
    Button(action: run) {
      Label(title, systemImage: symbol)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
    }
    .buttonStyle(.borderless)
    .padding(.horizontal, 6)
    .padding(.vertical, 3)
  }

  private func show(_ open: () -> Void) {
    dismiss()
    NSApp.activate()
    open()
  }
}
