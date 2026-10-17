import StowawayCore
import SwiftUI

/// First launch, in four short steps. Every step can be skipped ("Set Up Later", or Esc), and
/// onboarding doesn't come back once finished or skipped: the library's empty state and Settings
/// cover everything it asks for.
struct OnboardingView: View {
  @Bindable var model: AppModel
  @State private var step: Step
  /// Checked by default, and applied only when the user clicks Done, so nothing runs at login
  /// without their say-so.
  @State private var openAtLogin = true

  enum Step: Int, CaseIterable {
    case welcome, projects, caches, finish
  }

  init(model: AppModel, step: Step = .welcome) {
    self.model = model
    _step = State(initialValue: step)
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch step {
      case .welcome: welcome
      case .projects: projects
      case .caches: caches
      case .finish: finish
      }
      Spacer(minLength: 0)
      footer
    }
    .padding(24)
    .frame(width: 560)
    .frame(minHeight: 460)
  }

  // MARK: Steps

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(spacing: 12) {
        Image(nsImage: Logo.image(size: 44)).accessibilityHidden(true)
        Text("Get your disk space back").font(.title.weight(.semibold))
      }
      Text(
        "Stowaway finds the folders your tools can re-create (node_modules, Cargo and Xcode build files, package caches) and deletes them for you, or keeps them on an external drive."
      )
      VStack(alignment: .leading, spacing: 8) {
        Label("Never touches source code, or anything git tracks.", systemImage: "checkmark.shield")
        Label(
          "Offloaded folders stay where your tools expect them.",
          systemImage: "folder.badge.gearshape")
        Label(
          "Unplug the drive any time: builds keep working.",
          systemImage: "externaldrive.badge.checkmark")
      }
    }
  }

  private var projects: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Where do you keep your code?").font(.title2.weight(.semibold))
      Text(
        "macOS only lets Stowaway see folders you choose. It looks at folder names and sizes, never inside your files."
      )
      .foregroundStyle(.secondary)
      ForEach(model.roots, id: \.self) { root in
        Label(Format.path(root), systemImage: "checkmark.circle.fill")
      }
      let suggestions = Array(model.suggestedProjectFolders.prefix(3))
      ForEach(suggestions, id: \.self) { suggestion in
        if suggestion == suggestions.first {
          suggest(suggestion).buttonStyle(.borderedProminent)
        } else {
          suggest(suggestion)
        }
      }
      Button(suggestions.isEmpty ? "Choose a Folder…" : "Choose Another Folder…") {
        model.addRoot(startingAt: realHomeDirectory)
      }
      found
    }
    .task { await model.detectProjectFolders() }
  }

  private var caches: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Shared caches").font(.title2.weight(.semibold))
      Text(
        "These are on your Mac but outside your projects. Allow them all at once, or one at a time: the window opens in the right place, so just click Choose."
      )
      .foregroundStyle(.secondary)
      let pending = model.ungrantedCaches
      if !pending.isEmpty {
        Button("Allow All…") { model.allowHomeFolder() }
          .buttonStyle(.borderedProminent)
          .help("Lets Stowaway see your home folder, which covers every cache below.")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 10) {
          ForEach(allowedCaches, id: \.kind) { cache in
            HStack {
              Label(cache.kind.label, systemImage: "checkmark.circle.fill")
              Spacer()
              Text(cache.bytes.map(Format.bytes) ?? "Measuring…")
                .monospacedDigit().foregroundStyle(.secondary)
            }
          }
          ForEach(pending, id: \.folder) { cache in
            HStack {
              VStack(alignment: .leading, spacing: 2) {
                Text(cache.kind.label)
                Text(Format.path(cache.folder.path)).font(.caption).foregroundStyle(.secondary)
              }
              Spacer()
              Text(cache.kind.typicalSize).font(.callout).foregroundStyle(.secondary)
              Button("Allow…") {
                model.addRoot(
                  startingAt: cache.folder,
                  message:
                    "Click Choose to let Stowaway manage \(cache.kind.label) in \(Format.path(cache.folder.path))."
                )
              }
              .accessibilityLabel("Allow \(cache.kind.label)")
            }
          }
          if pending.isEmpty && allowedCaches.isEmpty {
            Text("No shared caches on this Mac.").foregroundStyle(.secondary)
          }
        }
      }
      .frame(maxHeight: 220)
      if !pending.isEmpty {
        Text("Typical sizes until allowed; Stowaway measures the real size after.")
          .font(.caption).foregroundStyle(.secondary)
      }
    }
  }

  private var finish: some View {
    VStack(alignment: .leading, spacing: 14) {
      Text("Almost done").font(.title2.weight(.semibold))
      VStack(alignment: .leading, spacing: 8) {
        Text("Offload to an external drive (optional)").font(.headline)
        if let name = model.driveName {
          Label(name, systemImage: "externaldrive.fill")
          Text(
            "Folders left unchanged for 5 minutes move there automatically, up to \(Format.bytes(Store.freeOffloadLimit)) free. You can change this in Settings."
          )
          .font(.callout).foregroundStyle(.secondary)
        } else {
          HStack {
            ForEach(Array(model.externalVolumes.prefix(3)), id: \.self) { volume in
              Button("Use \(volume.lastPathComponent)") { model.chooseDrive(volume) }
            }
            Button(model.externalVolumes.isEmpty ? "Choose a Location…" : "Somewhere Else…") {
              model.chooseDrive()
            }
          }
          Text(
            "No drive? Skip this: you can still find and delete folders, and choose a drive later."
          )
          .font(.callout).foregroundStyle(.secondary)
        }
      }
      Divider()
      Toggle(isOn: $openAtLogin) {
        VStack(alignment: .leading, spacing: 2) {
          Text("Open Stowaway at login")
          Text("So it can switch to local folders whenever the drive is unplugged.")
            .font(.caption).foregroundStyle(.secondary)
        }
      }
      HStack(alignment: .top, spacing: 10) {
        Image(nsImage: MenuBarImage.image(badge: nil)).accessibilityHidden(true)
        Text(
          "Stowaway lives in the menu bar. Click its icon any time, or open Stowaway again to bring back its window."
        )
        .font(.callout).foregroundStyle(.secondary)
      }
    }
  }

  // MARK: Parts

  /// A button that opens the folder panel at a suggested project folder.
  private func suggest(_ suggestion: ProjectFinder.Suggestion) -> some View {
    let path = Format.path(suggestion.folder.path)
    let count = suggestion.projects
    return Button(
      count > 0 ? "Use \(path) (\(count) project\(count == 1 ? "" : "s"))" : "Use \(path)"
    ) {
      model.addRoot(
        startingAt: suggestion.folder, message: "Click Choose to let Stowaway look in \(path).")
    }
  }

  /// What the scan has found so far, under the project step.
  @ViewBuilder private var found: some View {
    if model.scanning {
      Label("Looking…", systemImage: "magnifyingglass").foregroundStyle(.secondary)
    } else if !model.roots.isEmpty {
      let count = model.rows.filter { !$0.kind.isGlobal }.count
      Label(
        count == 0
          ? "Nothing to tidy up there yet."
          : "Found \(count) folder\(count == 1 ? "" : "s") you can reclaim, \(Format.bytes(model.reclaimableBytes)) in all.",
        systemImage: "sparkles"
      )
      .font(.headline)
    }
  }

  /// Caches Stowaway can already see, with their measured size (nil while measuring).
  private var allowedCaches: [(kind: Kind, bytes: Int64?)] {
    Dictionary(grouping: model.rows.filter(\.kind.isGlobal), by: \.kind)
      .map { kind, rows in
        let sizes = rows.map { $0.place == .drive ? $0.driveBytes : $0.localBytes }
        return (kind, sizes.contains(nil) ? nil : sizes.compactMap { $0 }.reduce(0, +))
      }
      .sorted { $0.kind.label < $1.kind.label }
  }

  private var footer: some View {
    HStack {
      Button("Set Up Later") { model.skipOnboarding() }
        .keyboardShortcut(.cancelAction)
      Spacer()
      Text("Step \(step.rawValue + 1) of \(Step.allCases.count)")
        .font(.caption).foregroundStyle(.secondary)
      Spacer()
      if step != .welcome {
        Button("Back") { move(-1) }.keyboardShortcut("[", modifiers: .command)
      }
      if step == .finish {
        Button("Done") { model.finishOnboarding(openAtLogin: openAtLogin) }
          .keyboardShortcut(.defaultAction)
      } else {
        Button(step == .welcome ? "Get Started" : "Continue") { move(1) }
          .keyboardShortcut(.defaultAction)
      }
    }
  }

  private func move(_ by: Int) {
    step = Step(rawValue: step.rawValue + by) ?? step
  }
}

extension Kind {
  /// A typical size, shown before Stowaway can measure a cache.
  fileprivate var typicalSize: String {
    switch self {
    case .xcodeDerivedData: "often 10–100 GB"
    case .huggingface: "often 10–500 GB"
    case .gradleHome: "often 5–50 GB"
    case .go, .pnpmStore: "often 2–30 GB"
    case .cargoHome: "often 1–10 GB"
    case .jsCaches: "often 1–20 GB"
    case .npx: "often 1–5 GB"
    default: ""
    }
  }
}
