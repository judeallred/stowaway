import AppKit
import StowawayKit
import SwiftUI

/// The Configure Folders window: watched roots, add with a preview, remove with a choice of what
/// happens to the offloaded data (spec §8).
struct ConfigureFoldersView: View {
  let model: AppModel
  @State private var selection: RootReport.ID?
  @State private var pendingAdd: PendingAdd?
  @State private var pendingRemove: RootReport?

  struct PendingAdd: Identifiable {
    let path: String
    let preview: RootPreview
    var id: String { path }
  }

  private var roots: [RootReport] { model.status?.roots ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      Table(roots, selection: $selection) {
        TableColumn("Folder") { root in
          HStack {
            Image(systemName: root.exists ? "folder" : "questionmark.folder")
            Text(Format.abbreviatedPath(root.path))
          }
        }
        TableColumn("Managed") { root in Text("\(root.entries)") }
          .width(70)
        TableColumn("Offloaded") { root in Text(Format.bytes(root.offloadedBytes)) }
          .width(90)
      }
      .overlay {
        if roots.isEmpty {
          Text("No watched folders yet. Add your code folder, e.g. ~/code.")
            .foregroundStyle(.secondary)
        }
      }
      Divider()
      toolbar
    }
    .frame(minWidth: 520, minHeight: 300)
    .alert(
      addTitle,
      isPresented: Binding(get: { pendingAdd != nil }, set: { if !$0 { pendingAdd = nil } }),
      presenting: pendingAdd
    ) { add in
      Button("Add Folder") {
        Task { await model.perform(.rootsAdd(path: add.path, dryRun: false), message: "Adding…") }
      }
      Button("Cancel", role: .cancel) {}
    } message: { add in
      Text(
        "Found \(add.preview.projects) projects. \(Format.bytes(add.preview.offloadableBytes)) can be offloaded as they go idle."
      )
    }
    .confirmationDialog(
      removeTitle,
      isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } }),
      presenting: pendingRemove
    ) { root in
      Button("Release (dependencies download again when needed)") {
        remove(root, copy: false)
      }
      if canBringBack(root) {
        Button("Bring Back to This Mac (\(Format.bytes(root.offloadedBytes)))") {
          remove(root, copy: true)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { root in
      Text(removeMessage(root))
    }
  }

  private var toolbar: some View {
    HStack(spacing: 4) {
      Button(action: chooseFolder) { Image(systemName: "plus") }
        .help("Add a folder of projects")
      Button {
        pendingRemove = roots.first { $0.id == selection }
      } label: {
        Image(systemName: "minus")
      }
      .disabled(selection == nil)
      .help("Stop watching the selected folder")
      Spacer()
      if let message = model.busyMessage {
        ProgressView().controlSize(.small)
        Text(message).font(.caption).foregroundStyle(.secondary)
      } else if let error = model.lastError {
        Text(error).font(.caption).foregroundStyle(.red).lineLimit(2)
      }
    }
    .buttonStyle(.borderless)
    .padding(8)
  }

  private var addTitle: String {
    pendingAdd.map { "Watch \(Format.abbreviatedPath($0.path))?" } ?? ""
  }

  private var removeTitle: String {
    pendingRemove.map { "Stop watching \(Format.abbreviatedPath($0.path))?" } ?? ""
  }

  private func removeMessage(_ root: RootReport) -> String {
    if model.status?.drive.connected != true {
      return "Connect the drive to bring its data back to this Mac."
    }
    if !canBringBack(root) {
      return
        "There isn't enough free space on this Mac to bring \(Format.bytes(root.offloadedBytes)) back."
    }
    return "\(root.entries) managed folders hold \(Format.bytes(root.offloadedBytes)) on the drive."
  }

  private func canBringBack(_ root: RootReport) -> Bool {
    guard model.status?.drive.connected == true else { return false }
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
    return free > Int64(clamping: root.offloadedBytes)
  }

  private func remove(_ root: RootReport, copy: Bool) {
    Task {
      await model.perform(
        .rootsRemove(path: root.path, copy: copy),
        message: copy ? "Copying back to this Mac…" : "Releasing…")
    }
  }

  private func chooseFolder() {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Choose"
    panel.message = "Choose a folder of projects to watch"
    guard panel.runModal() == .OK, let url = panel.url else { return }
    Task {
      model.busyMessage = "Looking for projects…"
      defer { model.busyMessage = nil }
      do {
        if let preview = try await model.previewRoot(url.path) {
          pendingAdd = PendingAdd(path: url.path, preview: preview)
          model.lastError = nil
        }
      } catch {
        model.lastError = error.localizedDescription
      }
    }
  }
}
