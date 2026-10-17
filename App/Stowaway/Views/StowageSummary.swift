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
