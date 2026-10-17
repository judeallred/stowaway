import StowawayCore
import SwiftUI

/// First launch: what Stowaway does, and the permissions it needs, one step at a time. Every
/// step can be skipped and revisited in Settings.
struct OnboardingView: View {
  @Bindable var model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var step: Step

  init(model: AppModel, step: Step = .welcome) {
    self.model = model
    _step = State(initialValue: step)
  }

  enum Step: Int, CaseIterable {
    case welcome, folders, caches, drive, login
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      switch step {
      case .welcome: welcome
      case .folders: folders
      case .caches: caches
      case .drive: drive
      case .login: login
      }
      Spacer(minLength: 0)
      HStack {
        if step != .welcome {
          Button("Back") { move(-1) }
        }
        Spacer()
        Text("\(step.rawValue + 1) of \(Step.allCases.count)").font(.caption).foregroundStyle(
          .secondary)
        Spacer()
        if step == .login {
          Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        } else {
          Button(step == .welcome ? "Get Started" : "Continue") { move(1) }.keyboardShortcut(
            .defaultAction)
        }
      }
    }
    .padding(24)
    .frame(width: 520, height: 420)
  }

  private func move(_ by: Int) {
    step = Step(rawValue: step.rawValue + by) ?? step
  }

  private var welcome: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(spacing: 12) {
        Image(nsImage: Logo.image(size: 44))
        Text("Welcome to Stowaway").font(.title.weight(.semibold))
      }
      Text(
        "Your Mac fills up with folders your tools can re-create: node_modules, Cargo and Xcode build files, package caches, downloaded models."
      )
      Text(
        "Stowaway finds them and lets you delete them. Or, with an external drive, it keeps them there instead:"
      )
      VStack(alignment: .leading, spacing: 6) {
        Label("Your tools see the folders where they always were.", systemImage: "checkmark.circle")
        Label(
          "Unplug the drive and they rebuild locally, without asking.",
          systemImage: "checkmark.circle")
        Label(
          "Plug it back in and everything moves back to the drive.", systemImage: "checkmark.circle"
        )
      }
      .foregroundStyle(.secondary)
      Text("Stowaway never touches source code, and never touches folders git tracks.").font(
        .callout)
    }
  }

  private var folders: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Where are your projects?").font(.title2.weight(.semibold))
      Text(
        "Choose the folder that holds your projects, such as ~/code. Stowaway can only see folders you choose, and you can add more later."
      )
      .foregroundStyle(.secondary)
      rootList
      Button("Choose a Folder…") {
        model.addRoot(startingAt: realHomeDirectory)
      }
    }
  }

  private var caches: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Shared caches").font(.title2.weight(.semibold))
      Text(
        "These caches are on your Mac but outside your projects. To include one, allow Stowaway access to the folder that holds it: the window opens there, so just click Choose."
      )
      .foregroundStyle(.secondary)
      let caches = model.ungrantedCaches
      if caches.isEmpty {
        Label("Nothing more to allow.", systemImage: "checkmark.circle").foregroundStyle(.secondary)
      } else {
        ScrollView {
          VStack(alignment: .leading, spacing: 8) {
            ForEach(caches, id: \.folder) { cache in
              HStack {
                VStack(alignment: .leading) {
                  Text(cache.kind.label)
                  Text(Format.path(cache.folder.path)).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Allow…") {
                  model.addRoot(
                    startingAt: cache.folder,
                    message:
                      "Click Choose to let Stowaway manage \(cache.kind.label) in \(Format.path(cache.folder.path))."
                  )
                }
              }
            }
          }
        }
        .frame(maxHeight: 200)
      }
    }
  }

  private var drive: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Have an external drive?").font(.title2.weight(.semibold))
      Text(
        "Choose it, or a folder on it, to keep folders there instead of deleting them. Offloading up to \(Format.bytes(Store.freeOffloadLimit)) is free."
      )
      .foregroundStyle(.secondary)
      if let drive = model.drivePath {
        Label(Format.path(drive), systemImage: "externaldrive.fill")
      }
      Button(model.drivePath == nil ? "Choose Offload Location…" : "Choose a Different Location…") {
        model.chooseDrive()
      }
      Text("No drive? Skip this; you can still find and delete folders.").font(.callout)
        .foregroundStyle(.secondary)
    }
  }

  private var login: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Keep Stowaway running").font(.title2.weight(.semibold))
      Text(
        "When the drive is unplugged, Stowaway switches offloaded folders to local ones so your builds keep working. It can only do that while it's running."
      )
      .foregroundStyle(.secondary)
      Toggle(
        "Open Stowaway at login",
        isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
      Text(
        "Stowaway lives in the menu bar and uses almost no resources while idle. You can change this in Settings."
      )
      .font(.callout).foregroundStyle(.secondary)
    }
  }

  private var rootList: some View {
    VStack(alignment: .leading, spacing: 4) {
      ForEach(model.roots, id: \.self) { root in
        Label(Format.path(root), systemImage: "folder.fill")
      }
    }
  }
}
