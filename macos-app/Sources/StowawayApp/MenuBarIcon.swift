import StowawayKit
import SwiftUI

/// The menu bar glyph: a template SF Symbol per state, gently animated while data moves.
struct MenuBarIcon: View {
  let model: AppModel
  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    let state = model.iconState
    Image(systemName: state.symbolName(frame: model.animationFrame, reduceMotion: reduceMotion))
      .accessibilityLabel(state.accessibilityLabel)
  }
}
