import SwiftUI

/// "8.9 GB stowed", what that takes on the drive once deduplicated, then how much more is on
/// this Mac to stow. Leads the menu and the main window. Hovering a moment shows the breakdown.
struct StowedHeadline: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(Format.bytes(model.offloadedBytes)) stowed")
        .font(.title2.weight(.semibold)).monospacedDigit()
      Group {
        if model.savedBySharing > 0 {
          Text("\(Format.bytes(model.stowedOnDrive)) stored on drive")
          Text("\(Format.bytes(model.savedBySharing)) deduplicated")
        }
        Text(toStow)
      }
      .font(.callout).foregroundStyle(.secondary).monospacedDigit()
    }
    .contentShape(Rectangle())
    .hoverDetail(after: .seconds(1.5)) { StowedBreakdown(model: model) }
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

/// The headline's numbers in full, and what deduplication is. Shown on hover.
struct StowedBreakdown: View {
  let model: AppModel

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {
      Text("What's stowed").font(.headline)
      Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 4) {
        row("Stowed folders hold", model.offloadedBytes)
        if model.savedBySharing > 0 {
          row("Stored on the drive", model.stowedOnDrive)
          row("Deduplicated", model.savedBySharing, note: percent)
        }
        if model.pendingBytes > 0 {
          row("Still on this Mac to stow", model.pendingBytes)
        }
      }
      .monospacedDigit()
      Divider()
      Text(explanation)
        .font(.callout).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(14)
    .frame(width: 340)
  }

  private func row(_ label: String, _ bytes: Int64, note: String? = nil) -> some View {
    GridRow {
      Text(label)
      Text(Format.bytes(bytes)).gridColumnAlignment(.trailing)
      Text(note ?? "").foregroundStyle(.secondary)
    }
  }

  /// "37%": the share of what's stowed that deduplication saves.
  private var percent: String? {
    guard model.offloadedBytes > 0 else { return nil }
    return "\(Int((Double(model.savedBySharing) / Double(model.offloadedBytes) * 100).rounded()))%"
  }

  private var explanation: String {
    var text =
      "Files that are exactly the same in several stowed folders (the same dependencies built in each worktree, say) are stored on the drive once and shared, using APFS clones. Each folder still works on its own: changing a file in one makes that copy its own again, and never changes it in another. Stowaway finds identical files in the background when it has nothing else to do, and clones a file the drive already has instead of copying it again."
    if model.driveCanShare == false {
      text =
        "\(model.driveFormat ?? "This drive's format") can't deduplicate: identical files are each stored in full. A drive formatted as APFS stores them once."
    }
    return text + " Stowed sizes, and the free stowage, count every file in full."
  }
}

extension View {
  /// Shows `content` in a popover once the pointer has rested on this view for `delay`, and
  /// hides it when the pointer leaves. (A tooltip's delay can't be set, and tooltips don't show
  /// in the menu bar's window.)
  func hoverDetail(after delay: Duration, @ViewBuilder content: @escaping () -> some View)
    -> some View
  {
    modifier(HoverDetail(delay: delay, detail: content))
  }
}

private struct HoverDetail<Detail: View>: ViewModifier {
  let delay: Duration
  let detail: () -> Detail
  @State private var showing = false
  @State private var pending: Task<Void, Never>?

  func body(content: Content) -> some View {
    content
      .onHover { inside in
        pending?.cancel()
        if inside {
          pending = Task {
            try? await Task.sleep(for: delay)
            if !Task.isCancelled { showing = true }
          }
        } else {
          showing = false
        }
      }
      .popover(isPresented: $showing, arrowEdge: .bottom) { detail() }
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
        Text(model.sweepStatus).lineLimit(2).monospacedDigit()
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
