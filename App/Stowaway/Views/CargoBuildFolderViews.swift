import StowawayCore
import SwiftUI

/// What the Cargo build folder setting does, in the words the wizard, Settings and the main
/// window share.
enum CargoBuildFolderText {
  static let title = "Build Rust projects on the drive"
  static let summary =
    "Cargo can keep most of every build (compiled dependencies and caches) in one shared folder. Stowaway keeps that folder on your drive, so each project and worktree builds there from the start, instead of filling your Mac until it's stowed."
  static let points: [(text: String, symbol: String)] = [
    (
      "New projects and worktrees don't fill your Mac with build files.",
      "externaldrive.badge.checkmark"
    ),
    (
      "Built programs stay in each project's target folder, so they run without the drive.",
      "hammer"
    ),
    (
      "Adds one line to ~/.cargo/config.toml. Turn it off in Settings any time.",
      "slider.horizontal.3"
    ),
  ]
  static let requirements =
    "Needs Rust 1.91 or later. While the drive is unplugged, Cargo builds on your Mac as usual. Projects that set their own build-dir keep it."
}

/// On the main window when a lot of Cargo build files have been stowed and the setting is off.
/// Dismissing it is for good; the setting stays in Settings.
struct CargoBuildFolderSuggestion: View {
  let model: AppModel

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      Image(systemName: "hammer.fill").font(.title2).foregroundStyle(.tint)
        .accessibilityHidden(true)
      VStack(alignment: .leading, spacing: 6) {
        Text(CargoBuildFolderText.title).font(.headline)
        Text(
          "\(Format.bytes(model.stowedCargoBytes)) of Cargo build files were built on this Mac, then stowed. Cargo can build straight onto the drive instead: every project and worktree, from its first build."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        HStack {
          Button("Turn On…") { model.turnOnCargoBuildFolder() }
            .buttonStyle(.borderedProminent)
          Button("Dismiss") { model.cargoSuggestionDismissed = true }
            .help("Don't suggest this again. It stays in Settings.")
        }
        .padding(.top, 2)
      }
      Spacer(minLength: 0)
    }
    .padding(16)
    .background(.tint.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.tint.opacity(0.3)))
  }
}
