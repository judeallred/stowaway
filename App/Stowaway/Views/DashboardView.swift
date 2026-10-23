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
        MessageLine(model: model)
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
          .accessibilityHidden(true)  // the text beside it says the same
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
    EmptyState.noFolders(
      model,
      detail:
        "Stowaway finds node_modules, build folders and caches in the folders you choose, and stows them on your drive automatically."
    )
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

/// Totals and the drive, at the top of the main window. Everything is top-aligned with the drive button,
/// which stays in the same place whether or not a drive is chosen.
struct SummaryHeader: View {
  let model: AppModel
  /// The drive column's width: the button, and the bar or explanation under it.
  static let driveWidth: CGFloat = 230

  var body: some View {
    HStack(alignment: .top, spacing: 24) {
      StowedHeadline(model: model)
      Spacer()
      if let plan = model.store.planName {
        PlanBadge(plan: plan) { model.showingSupport = true }
          .padding(.top, 4)
      }
      if let left = model.freeAllowanceLeft {
        VStack(alignment: .leading, spacing: 6) {
          StorageBar(
            segments: [(Store.freeOffloadLimit - left, .accentColor)],
            total: Store.freeOffloadLimit
          )
          .frame(width: 160)
          .padding(.top, 8)
          .accessibilityLabel("Free stowage used")
          .accessibilityValue(
            "\(Format.bytes(Store.freeOffloadLimit - left)) of \(Format.bytes(Store.freeOffloadLimit))"
          )
          Text(
            model.freeStowageFull
              ? "Free stowage is full" : "\(Format.bytes(left)) of free stowage left"
          )
          .font(.caption)
          .foregroundStyle(
            model.freeStowageFull ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
          )
          .fixedSize()
          Button("Go Unlimited…") { model.showingSupport = true }
            .buttonStyle(.link).font(.caption)
        }
        // When it's full, a box calls attention to it (drawn outside, so nothing moves).
        .padding(8)
        .background {
          if model.freeStowageFull {
            RoundedRectangle(cornerRadius: 8)
              .fill(.orange.opacity(0.1))
              .strokeBorder(.orange.opacity(0.7), lineWidth: 1)
          }
        }
        .padding(-8)
      }
      VStack(alignment: .leading, spacing: 6) {
        DriveButton(model: model)
        DriveStats(model: model)
      }
      .frame(width: Self.driveWidth)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

/// After a purchase: the logo with a heart, and the plan. Opens the thank-you sheet.
private struct PlanBadge: View {
  let plan: String
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        Image(nsImage: Logo.image(size: 30))
          .overlay(alignment: .bottomTrailing) {
            Image(systemName: "heart.fill")
              .font(.system(size: 11))
              .foregroundStyle(.red)
              .shadow(color: .black.opacity(0.3), radius: 1)
              .offset(x: 4, y: 3)
          }
        VStack(alignment: .leading, spacing: 1) {
          Text(plan).font(.callout.weight(.semibold))
          Text("Unlimited stowage").font(.caption).foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Thank you! Click to see your purchase, or support us again.")
    .accessibilityLabel("Plan: \(plan). Unlimited stowage.")
  }
}

private struct DriveButton: View {
  let model: AppModel

  var body: some View {
    if let name = model.driveName {
      HStack(spacing: 6) {
        Button {
          model.chooseDrive()
        } label: {
          Label(
            name,
            systemImage: model.driveSymbol
          )
          .lineLimit(1)
          .frame(maxWidth: .infinity)
        }
        .help(
          "Stowing on \(model.drivePath.map(Format.path) ?? name)\(model.driveConnected ? "" : " (disconnected)"). Click to choose a different drive."
        )
        if model.driveConnected {
          Button {
            model.ejectDrive()
          } label: {
            Image(systemName: "eject")
          }
          .help("Eject \(name)")
          .accessibilityLabel("Eject \(name)")
        }
        Menu {
          Button("Choose a Different Drive…") { model.chooseDrive() }
          Button("Stop Using \(name)…") { model.stopUsingDrive() }
        } label: {
          Image(systemName: "ellipsis")
        }
        .disabled(model.stoppingDrive)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Drive options")
      }
      .controlSize(.large)
    } else {
      Button {
        model.chooseDrive()
      } label: {
        Label("Choose a Drive…", systemImage: "externaldrive.badge.plus")
          .lineLimit(1)
          .frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .help("Choose a drive, or a folder on one, to stow folders on")
    }
  }
}

/// Under the drive button: space on the drive, or, before one is chosen, what it's for.
private struct DriveStats: View {
  let model: AppModel

  var body: some View {
    if model.driveName == nil {
      Text(
        "Keep folders on a drive instead of deleting them. Your tools still find them."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } else if model.driveConnected, let free = model.driveFreeBytes,
      let total = model.driveTotalBytes, total > 0
    {
      VStack(alignment: .trailing, spacing: 3) {
        DriveSpaceBar(model: model, free: free, total: total)
        Text(
          "\(Format.bytes(model.offloadedBytes)) stowed · \(Format.bytes(free)) free of \(Format.bytes(total))"
        )
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
    } else if !model.driveConnected {
      Text("Disconnected: your tools use local folders meanwhile.")
        .font(.caption).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
    }
  }
}
