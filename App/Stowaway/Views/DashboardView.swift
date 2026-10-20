import StowawayCore
import SwiftUI

/// The main window: what's stowed, the drive, what Stowaway is doing, and how it breaks down.
/// Stowing is automatic, so this shows rather than asks; the folder list is a click away.
struct DashboardView: View {
  @Bindable var model: AppModel
  @Environment(\.openWindow) private var openWindow

  var body: some View {
    VStack(spacing: 0) {
      SummaryHeader(model: model)
      Divider()
      if model.roots.isEmpty {
        firstRun
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 24) {
            status
            breakdown
          }
          .padding(20)
          .frame(maxWidth: .infinity, alignment: .leading)
        }
      }
      Divider()
      HStack {
        if let message = model.message {
          Label(message, systemImage: "exclamationmark.triangle")
            .font(.callout).foregroundStyle(.orange).lineLimit(2)
        }
        Spacer()
        Button("Folders…") { openWindow(id: WindowID.folders) }
          .help("Every folder Stowaway manages, to stow, bring back or delete by hand.")
      }
      .padding(10)
    }
    .toolbar {
      ToolbarItem {
        SettingsLink { Label("Settings", systemImage: "gearshape") }
          .help("Settings")
      }
    }
  }

  // MARK: Parts

  /// What's happening now, plus anything waiting or stuck.
  private var status: some View {
    VStack(alignment: .leading, spacing: 8) {
      StowStatus(model: model).font(.title3)
      let waiting = model.queued.count
      if waiting > 0 {
        Text("\(Format.count(waiting, "more folder")) queued.").foregroundStyle(.secondary)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(16)
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
  }

  /// Stowed and still-on-this-Mac bytes for each kind of folder.
  private var breakdown: some View {
    let kinds = Self.totals(model)
    let largest = kinds.map { $0.stowed + $0.onMac }.max() ?? 0
    return VStack(alignment: .leading, spacing: 10) {
      Text("By kind").font(.headline)
      if kinds.isEmpty {
        Text(model.scanning ? "Looking…" : "Nothing re-creatable found yet.")
          .foregroundStyle(.secondary)
      }
      ForEach(kinds, id: \.kind) { item in
        HStack(spacing: 12) {
          Text(item.kind.label).frame(width: 190, alignment: .leading).lineLimit(1)
          StorageBar(
            segments: [(item.stowed, .accentColor), (item.onMac, Color.gray.opacity(0.55))],
            total: max(largest, 1)
          )
          Text(
            [
              item.stowed > 0 ? "\(Format.bytes(item.stowed)) stowed" : nil,
              item.onMac > 0 ? "\(Format.bytes(item.onMac)) to stow" : nil,
            ].compactMap { $0 }.joined(separator: " · ")
          )
          .font(.callout).foregroundStyle(.secondary).monospacedDigit()
          .frame(width: 210, alignment: .trailing)
        }
      }
    }
  }

  /// Before any folder is chosen.
  private var firstRun: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(nsImage: Logo.image(size: 48)).opacity(0.6).accessibilityHidden(true)
      Text("Choose the folders Stowaway looks in").font(.title3.weight(.semibold))
      Text(
        "Stowaway finds node_modules, build folders and caches in the folders you choose, and stows them on your drive automatically."
      )
      .foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
      Button("Choose a Folder…") { model.addRoot() }.controlSize(.large)
      Button("Or Create a Sample Project to Try It…") { model.createSampleProject() }
        .buttonStyle(.link)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }

  /// Per kind, largest first, leaving out folders Stowaway can't stow.
  static func totals(_ model: AppModel) -> [(kind: Kind, stowed: Int64, onMac: Int64)] {
    Dictionary(grouping: model.rows.filter { !model.cantStow($0) }, by: \.kind)
      .map { kind, rows in
        let stowed = rows.filter { $0.place != .mac }.map(\.driveBytes).reduce(0, +)
        let onMac = rows.filter { $0.place == .mac }.compactMap(\.localBytes).reduce(0, +)
        return (kind, stowed, onMac)
      }
      .filter { $0.stowed + $0.onMac > 0 }
      .sorted { $0.stowed + $0.onMac > $1.stowed + $1.onMac }
  }
}
