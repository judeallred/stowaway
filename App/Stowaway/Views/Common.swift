import StowawayCore
import SwiftUI

/// A window's placeholder when there's nothing to show, with what to do about it.
struct EmptyState: View {
  let title: String
  let detail: String
  let button: String
  var link: (title: String, action: () -> Void)?
  let action: () -> Void

  init(
    title: String, detail: String, button: String,
    link: (title: String, action: () -> Void)? = nil, action: @escaping () -> Void
  ) {
    self.title = title
    self.detail = detail
    self.button = button
    self.link = link
    self.action = action
  }

  /// Before any folder is chosen: choose one, or try the sample.
  static func noFolders(_ model: AppModel, detail: String) -> EmptyState {
    EmptyState(
      title: "Choose the folders Stowaway looks in", detail: detail, button: "Choose a Folder…",
      link: ("Or Create a Sample Project to Try It…", { model.createSampleProject() })
    ) { model.addRoot() }
  }

  var body: some View {
    VStack(spacing: 12) {
      Spacer()
      Image(nsImage: Logo.image(size: 48)).opacity(0.6).accessibilityHidden(true)
      Text(title).font(.title3.weight(.semibold))
      Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 440)
      Button(button, action: action).controlSize(.large)
      if let link {
        Button(link.title, action: link.action).buttonStyle(.link)
      }
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }
}

/// The latest problem (`message`) or good news (`info`), for a window's bottom bar.
struct MessageLine: View {
  let model: AppModel

  var body: some View {
    if let message = model.message {
      Label(message, systemImage: "exclamationmark.triangle")
        .font(.callout).foregroundStyle(.orange).lineLimit(2)
    } else if let info = model.info {
      Label(info, systemImage: "checkmark.circle")
        .font(.callout).foregroundStyle(.secondary).lineLimit(2)
    }
  }
}

/// The drive's space: stowed by Stowaway (accent), other files (gray), free (the track).
struct DriveSpaceBar: View {
  let model: AppModel
  let free: Int64
  let total: Int64

  var body: some View {
    let used = max(0, total - free)
    let stowed = min(model.offloadedBytes, used)
    StorageBar(
      segments: [(stowed, .accentColor), (used - stowed, Color.gray.opacity(0.55))], total: total
    )
    .help(
      "\(Format.bytes(stowed)) stowed by Stowaway, \(Format.bytes(used - stowed)) other files, \(Format.bytes(free)) free"
    )
    .accessibilityElement()
    .accessibilityLabel("Drive space")
    .accessibilityValue(
      "\(Format.bytes(stowed)) stowed, \(Format.bytes(used - stowed)) other, \(Format.bytes(free)) free"
    )
  }
}

/// A capacity bar with several colored parts, like the one in Disk Utility. (ProgressView
/// shows only one value.)
struct StorageBar: View {
  let segments: [(bytes: Int64, color: Color)]
  let total: Int64

  var body: some View {
    GeometryReader { geometry in
      HStack(spacing: 0) {
        ForEach(segments.indices, id: \.self) { i in
          let fraction = total > 0 ? Double(max(0, segments[i].bytes)) / Double(total) : 0
          // Anything there gets at least a sliver, so 8 GB on a 2 TB drive still shows.
          segments[i].color.frame(
            width: segments[i].bytes > 0 ? max(3, geometry.size.width * min(1, fraction)) : 0)
        }
        Spacer(minLength: 0)
      }
      .background(Color.primary.opacity(0.1))
      .clipShape(Capsule())
    }
    .frame(height: 6)
  }
}
