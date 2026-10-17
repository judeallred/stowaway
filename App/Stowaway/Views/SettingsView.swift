import StowawayCore
import SwiftUI

struct SettingsView: View {
  @Bindable var model: AppModel

  var body: some View {
    TabView {
      FoldersSettings(model: model)
        .tabItem { Label("Folders", systemImage: "folder") }
      OffloadSettings(model: model)
        .tabItem { Label("Offload", systemImage: "externaldrive") }
      GeneralSettings(model: model)
        .tabItem { Label("General", systemImage: "gearshape") }
    }
    .frame(width: 520, height: 380)
  }
}

private struct FoldersSettings: View {
  let model: AppModel
  @State private var selection: String?

  var body: some View {
    Form {
      Section {
        List(model.roots, id: \.self, selection: $selection) { root in
          Label(Format.path(root), systemImage: "folder.fill")
        }
        .frame(minHeight: 120)
        HStack {
          Button("Add Folder…") { model.addRoot(startingAt: realHomeDirectory) }
          Button("Remove") {
            if let selection { model.removeRoot(selection) }
          }
          .disabled(selection == nil)
        }
      } header: {
        Text("Stowaway looks in these folders")
      } footer: {
        Text(
          "Removing a folder doesn't touch anything in it, and folders already offloaded stay on the drive. To skip a folder inside one of these, put a file named .stowaway-ignore in it."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      let caches = model.ungrantedCaches
      if !caches.isEmpty {
        Section("Caches Stowaway can't reach yet") {
          ForEach(caches, id: \.folder) { cache in
            HStack {
              Text("\(cache.kind.label) in \(Format.path(cache.folder.path))")
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
    }
    .formStyle(.grouped)
  }
}

private struct OffloadSettings: View {
  @Bindable var model: AppModel

  var body: some View {
    Form {
      Section("Offload location") {
        HStack {
          if let drive = model.drivePath {
            Label(
              Format.path(drive),
              systemImage: model.driveConnected ? "externaldrive.fill" : "externaldrive.badge.xmark"
            )
            if !model.driveConnected { Text("disconnected").foregroundStyle(.secondary) }
          } else {
            Text("None chosen").foregroundStyle(.secondary)
          }
          Spacer()
          Button(model.drivePath == nil ? "Choose…" : "Change…") { model.chooseDrive() }
        }
        if let free = model.driveFreeBytes {
          LabeledContent("Free space", value: Format.bytes(free))
        }
        LabeledContent("Offloaded", value: Format.bytes(model.offloadedBytes))
      }
      Section {
        Picker("Offload automatically", selection: $model.autoOffloadDays) {
          Text("Never (only when I choose)").tag(0)
          Text("After 1 day unchanged").tag(1)
          Text("After 1 week unchanged").tag(7)
          Text("After 1 month unchanged").tag(30)
        }
      } footer: {
        Text(
          "Project folders that haven't changed for this long move to the drive while it's connected."
        )
        .font(.caption).foregroundStyle(.secondary)
      }
      Section("Plan") {
        if let left = model.freeAllowanceLeft {
          LabeledContent("Free offloading left", value: Format.bytes(left))
          Button("Make It Unlimited…") { model.showingSupport = true }
        } else {
          Label("Unlimited offloading. Thank you!", systemImage: "heart.fill")
        }
      }
    }
    .formStyle(.grouped)
  }
}

private struct GeneralSettings: View {
  let model: AppModel

  var body: some View {
    Form {
      Section {
        Toggle(
          "Open Stowaway at login",
          isOn: Binding(get: { model.loginItemEnabled }, set: { model.setLoginItem($0) }))
      } footer: {
        Text("Stowaway can only switch offloaded folders to local ones while it's running.")
          .font(.caption).foregroundStyle(.secondary)
      }
      Section("Purchases") {
        Button("Restore Purchases") { Task { await model.store.restore() } }
      }
      Section("About") {
        LabeledContent("Version", value: version)
        Link("Stowaway Website", destination: Links.website)
        Link("Privacy Policy", destination: Links.privacyPolicy)
        Link("Get Help", destination: Links.support)
      }
    }
    .formStyle(.grouped)
  }

  private var version: String {
    let info = Bundle.main.infoDictionary
    return
      "\(info?["CFBundleShortVersionString"] as? String ?? "?") (\(info?["CFBundleVersion"] as? String ?? "?"))"
  }
}
