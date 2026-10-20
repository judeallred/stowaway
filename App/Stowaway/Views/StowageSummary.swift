import SwiftUI

/// "You've stowed X, with Y more pending stowage, out of Z of re-creatable data." Shown in the
/// library header and the menu. Stowed plus pending always equals the total.
struct StowageSummary: View {
  let model: AppModel
  /// Larger, for the library header.
  var prominent = false

  var body: some View {
    let stowed = Format.bytes(model.offloadedBytes)
    let pending = model.pendingBytes
    VStack(alignment: .leading, spacing: 2) {
      Text(
        "You've stowed \(Text(stowed).font(prominent ? .title3.weight(.semibold) : nil).foregroundStyle(.primary)),"
      )
      if pending > 0 {
        Text("with \(Text(Format.bytes(pending)).foregroundStyle(.primary)) more pending stowage,")
          .help(
            "Folders on this Mac that Stowaway can stow, by hand or automatically. Folders it can't stow (a pnpm project, say) aren't counted."
          )
      }
      Text(
        "out of \(Text(Format.bytes(model.eligibleBytes)).foregroundStyle(.primary)) of re-creatable data."
      )
    }
    .foregroundStyle(.secondary)
    .monospacedDigit()
  }
}

/// What Stowaway is doing now, or what happens next. Shown in the menu and the main window.
struct StowStatus: View {
  let model: AppModel

  var body: some View {
    if let activity = model.activity {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(activity).lineLimit(1).truncationMode(.middle)
      }
    } else if model.driveName != nil && !model.driveConnected {
      Label("Your tools use local folders until the drive is back.", systemImage: "info.circle")
    } else if model.driveName == nil {
      Label("Choose a drive to stow folders on.", systemImage: "info.circle")
    } else if model.autoOffloadMinutes == AppModel.AutoStow.never {
      Label("Automatic stowing is off.", systemImage: "pause.circle")
    } else if model.pendingBytes > 0 {
      Label(
        "Stows folders \(AppModel.AutoStow.describe(model.autoOffloadMinutes)).",
        systemImage: "clock")
    } else {
      Label("All caught up.", systemImage: "checkmark.circle")
    }
  }
}
