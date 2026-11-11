import SwiftUI

/// "8.9 GB stowed", then how much more is on this Mac to stow. Leads the menu and the main
/// window.
struct StowedHeadline: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(Format.bytes(model.offloadedBytes)) stowed")
        .font(.title2.weight(.semibold)).monospacedDigit()
      if model.savedBySharing > 0 {
        SharingSavings(model: model)
      }
      Text(toStow)
        .font(.callout).foregroundStyle(.secondary).monospacedDigit()
    }
  }

  /// What's left on this Mac. Sizes come after a scan's first stows, so until every folder is
  /// measured it counts folders rather than showing a partial (or zero) total.
  private var toStow: String {
    let pending = model.pendingRows
    if pending.isEmpty { return "Nothing left on this Mac to stow" }
    if pending.contains(where: { $0.localBytes == nil }) {
      return "\(Format.count(pending.count, "folder")) on this Mac to stow"
    }
    return "\(Format.bytes(model.pendingBytes)) more on this Mac to stow"
  }
}

/// The space identical files save by being stored on the drive once: shown off under the
/// stowed total.
struct SharingSavings: View {
  let model: AppModel

  var body: some View {
    Label {
      Text("\(Format.bytes(model.savedBySharing)) saved by deduplication")
    } icon: {
      Image(systemName: "square.on.square.fill")
    }
    .font(.callout.weight(.medium)).monospacedDigit()
    .foregroundStyle(.tint)
    .help(
      "Your stowed folders hold \(Format.bytes(model.offloadedBytes)) of files but take \(Format.bytes(model.stowedOnDrive)) on the drive: files that are the same in several folders (the same dependencies built in each worktree, say) are stored once and shared. Each folder still works on its own, and changing a file in one never changes it in another."
    )
  }
}

/// What Stowaway is doing now, or what happens next. Shown in the menu and the main window.
struct StowStatus: View {
  let model: AppModel

  var body: some View {
    content.fixedSize(horizontal: false, vertical: true)
  }

  @ViewBuilder private var content: some View {
    if let activity = model.activity {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(activity).lineLimit(2).truncationMode(.middle)
      }
    } else if model.sweeping {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(
          model.driveNearlyFull
            ? "Making room: storing identical files on the drive once…"
            : "Looking for identical files on the drive to store once…"
        )
        .lineLimit(2)
      }
    } else if model.paused {
      Label("Paused: nothing is stowed automatically until you resume", systemImage: "pause.circle")
    } else if let intent = model.stopIntent, let name = model.driveName {
      Label(
        intent == .quickDrop
          ? "Dropping \(name)…"
          : model.driveConnected
            ? "Stopping use of \(name): \(intent == .bringBack ? "bringing folders back" : "deleting stowed folders")"
            : "Connect \(name) to finish \(intent == .bringBack ? "bringing folders back" : "deleting stowed folders")",
        systemImage: "externaldrive.badge.minus")
    } else if model.driveName != nil && !model.driveConnected {
      Label("Your tools use local folders until the drive is back", systemImage: "info.circle")
    } else if model.driveName == nil {
      Label("Choose a drive to stow folders on", systemImage: "info.circle")
    } else if model.autoOffloadMinutes == AppModel.AutoStow.never {
      Label("Automatic stowing is off", systemImage: "pause.circle")
    } else if !model.pendingRows.isEmpty {
      Label(
        model.waitingSummary ?? AppModel.AutoStow.status(model.autoOffloadMinutes),
        systemImage: "clock")
    } else {
      Label("All caught up", systemImage: "checkmark.circle")
    }
  }
}
