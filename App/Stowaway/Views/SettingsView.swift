import StowawayCore
import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    TabView {
      FoldersSettings(model: model)
        .tabItem { Label("Folders", systemImage: "folder") }
      OffloadSettings(model: model)
        .tabItem { Label("Stow", systemImage: "externaldrive") }
      GeneralSettings(model: model)
        .tabItem { Label("General", systemImage: "gearshape") }
    }
    .frame(width: 520, height: 380)
  }
}

struct FoldersSettings: View {
  let model: AppModel
  @State private var selection: String?
  @State private var suggesting = false

  var body: some View {
    Form {
      Section {
        List(model.rootGroups, id: \.root, selection: $selection) { group in
          Label {
            VStack(alignment: .leading, spacing: 1) {
              Text(Format.path(group.root))
              if !group.nested.isEmpty {
                Text("Includes \(group.nested.map(Format.path).joined(separator: ", "))")
                  .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                  .truncationMode(.middle)
              }
            }
          } icon: {
            Image(systemName: "folder.fill")
          }
        }
        .frame(minHeight: 120)
        HStack {
          Button("Add Folder…") { model.addRoot(startingAt: realHomeDirectory) }
          let count = model.suggestionCount
          Button(count > 0 ? "Suggested Folders (\(count))…" : "Suggested Folders…") {
            suggesting = true
          }
          .popover(isPresented: $suggesting, arrowEdge: .bottom) {
            SuggestedFolders(model: model)
          }
          Button("Remove") {
            if let selection {
              model.removeRoot(selection)
              self.selection = nil
            }
          }
          .disabled(selection == nil)
        }
      } header: {
        Text("Stowaway looks in these folders")
      } footer: {
        Text(
          "Removing a folder doesn't touch anything in it. One with stowed folders in it can be removed once they're brought back. To skip a folder inside one of these, put a file named .stowaway-ignore in it."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
    }
    .formStyle(.grouped)
    .task { await model.detectProjectFolders() }
  }
}

struct OffloadSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section("Stow location") {
        HStack {
          if let name = model.driveName {
            Label(
              model.drivePath.map(Format.path) ?? name,
              systemImage: model.driveSymbol
            )
            if !model.driveConnected { Text("disconnected").foregroundStyle(.secondary) }
          } else {
            Text("None chosen").foregroundStyle(.secondary)
          }
          Spacer()
          Button(model.driveName == nil ? "Choose…" : "Change…") { model.chooseDrive() }
            .disabled(model.stoppingDrive)
          if model.driveName != nil {
            Button("Stop Using…") { model.stopUsingDrive() }
              .disabled(model.stoppingDrive)
          }
        }
        if model.driveConnected, let free = model.driveFreeBytes {
          LabeledContent("Free space") {
            if let total = model.driveTotalBytes, total > 0 {
              VStack(alignment: .trailing, spacing: 3) {
                Text("\(Format.bytes(free)) of \(Format.bytes(total))")
                DriveSpaceBar(model: model, free: free, total: total)
                  .frame(width: 140)
              }
            } else {
              Text(Format.bytes(free))
            }
          }
        }
        if model.driveConnected, let format = model.driveFormat {
          LabeledContent("Format", value: format)
        }
        LabeledContent("Stowed", value: Format.bytes(model.offloadedBytes))
      }
      if model.driveName != nil {
        Section {
          if let speed = model.driveSpeed {
            LabeledContent("Read", value: "\(Int(speed.readMBps).formatted()) MB/s")
            LabeledContent("Write", value: "\(Int(speed.writeMBps).formatted()) MB/s")
            LabeledContent(
              "Small files", value: "\(Int(speed.smallFilesPerSecond).formatted()) per second")
          }
          HStack {
            if let speed = model.driveSpeed {
              Label(speed.verdict, systemImage: speed.symbol).foregroundStyle(speed.color)
            } else if !model.testingSpeed {
              Text("Not tested yet").foregroundStyle(.secondary)
            }
            Spacer()
            if model.testingSpeed {
              ProgressView().controlSize(.small)
              Text("Testing…").foregroundStyle(.secondary)
            } else {
              Button(model.driveSpeed == nil ? "Test Speed" : "Test Again") {
                Task { await model.testDriveSpeed() }
              }
              .disabled(!model.driveConnected)
            }
          }
        } header: {
          Text("Speed")
        } footer: {
          Text(
            "Writes and reads a 256 MB file, and 2,000 small ones like node_modules has, then removes them."
          )
          .font(.caption).foregroundStyle(.secondary)
        }
      }
      Section {
        Picker("Stow automatically", selection: $model.autoOffloadMinutes) {
          ForEach(AppModel.AutoStow.choices, id: \.minutes) { Text($0.label).tag($0.minutes) }
        }
      } footer: {
        Text(
          "Folders that haven't changed for this long move to the drive while it's connected. Immediately moves them as soon as Stowaway finds them, so builds read and write on the drive: best with a fast one. A running Cargo build, or Xcode or a Gradle IDE that's open, holds off the folders they use."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Plan") {
        if model.store.hasPurchased {
          Label("Unlimited stowing. Thank you!", systemImage: "heart.fill")
        } else {
          if let left = model.freeAllowanceLeft {
            LabeledContent("Free stowage left", value: Format.bytes(left))
          }
          Button("Go Unlimited…") { model.showSupport() }
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct GeneralSettings: View {
  let model: AppModel
  /// What the last Restore Purchases found.
  @State private var restoreResult: String?

  var body: some View {
    Form {
      Section {
        Toggle(
          "Open Stowaway at login",
          isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
      } footer: {
        Text("Stowaway can only switch stowed folders to local ones while it's running.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Purchases") {
        HStack {
          Button("Restore Purchases") {
            restoreResult = nil
            Task { restoreResult = await model.store.restore() }
          }
          if let restoreResult {
            Text(restoreResult).font(.caption).foregroundStyle(.secondary)
          }
        }
      }
      Section("About") {
        LabeledContent("Version", value: Bundle.main.versionString)
        Link("Stowaway Website", destination: Links.website)
        Link("Privacy Policy", destination: Links.privacyPolicy)
        Link("Get Help", destination: Links.support)
      }
    }
    .formStyle(.grouped)
  }

}

extension DriveSpeed {
  var verdict: String {
    switch rating {
    case .fast: "Fast: fine for building on the drive, even stowing immediately."
    case .moderate: "Good for stowing. Builds on the drive will be slower than on your Mac."
    case .slow: "Slow. Best for folders you rarely use: stow after a day or more."
    }
  }

  var symbol: String {
    switch rating {
    case .fast: "hare"
    case .moderate: "gauge.with.dots.needle.50percent"
    case .slow: "tortoise"
    }
  }

  var color: Color {
    switch rating {
    case .fast: .green
    case .moderate: .primary
    case .slow: .orange
    }
  }
}

/// Folders Stowaway could look in but can't yet: where Spotlight finds projects, and shared
/// caches outside the chosen folders.
struct SuggestedFolders: View {
  let model: AppModel

  var body: some View {
    let projects = model.suggestedProjectFolders.filter { $0.projects > 0 }
    let caches = model.ungrantedCaches
    VStack(alignment: .leading, spacing: 10) {
      Text("Suggested folders").font(.headline)
      if projects.isEmpty && caches.isEmpty {
        Text("Stowaway can already see every folder it would suggest.")
          .foregroundStyle(.secondary)
      }
      if !projects.isEmpty {
        Text("Projects").font(.subheadline).foregroundStyle(.secondary)
        ForEach(projects, id: \.self) { suggestion in
          row(
            Format.path(suggestion.folder.path),
            Format.count(suggestion.projects, "project"),
            folder: suggestion.folder)
        }
      }
      if !caches.isEmpty {
        Text("Shared caches").font(.subheadline).foregroundStyle(.secondary)
        ForEach(caches, id: \.folder) { cache in
          row(cache.kind.label, Format.path(cache.folder.path), folder: cache.folder)
        }
        Button("Allow All…") { model.allowHomeFolder() }
          .help("Lets Stowaway see your home folder, which covers every cache above.")
      }
    }
    .padding(16)
    .frame(width: 380)
    .task { await model.detectProjectFolders() }
  }

  private func row(_ title: String, _ detail: String, folder: URL) -> some View {
    HStack {
      VStack(alignment: .leading, spacing: 1) {
        Text(title)
        Text(detail).font(.caption).foregroundStyle(.secondary)
      }
      Spacer()
      Button("Allow…") {
        model.addRoot(
          startingAt: folder,
          message: "Click Choose to let Stowaway look in \(Format.path(folder.path)).")
      }
      .accessibilityLabel("Allow \(title)")
    }
  }
}
