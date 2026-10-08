import AppKit
import StowawayKit
import SwiftUI

/// The Configure Folders window: what Stowaway does, which shared caches it offloads, and the
/// watched code folders, with a preview when adding one and a choice of what happens to the
/// offloaded data when removing one (spec §8).
struct ConfigureFoldersView: View {
  let model: AppModel
  @State private var selection: RootReport.ID?
  @State private var pendingAdd: PendingAdd?
  @State private var pendingRemove: RootReport?
  @State private var pendingDisable: GlobalReport?

  struct PendingAdd: Identifiable {
    let path: String
    let preview: RootPreview
    var id: String { path }
  }

  private var roots: [RootReport] { model.status?.roots ?? [] }

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      VStack(alignment: .leading, spacing: 20) {
        explainer
        cachesSection
        foldersSection
      }
      .padding(20)
      Divider()
      statusBar
    }
    .frame(minWidth: 600)
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
      if canBringBack(root.offloadedBytes) {
        Button("Bring Back to This Mac (\(Format.bytes(root.offloadedBytes)))") {
          remove(root, copy: true)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { root in
      Text(
        bringBackMessage(
          root.offloadedBytes,
          held:
            "\(root.entries) managed folders hold \(Format.bytes(root.offloadedBytes)) on the drive."
        ))
    }
    .confirmationDialog(
      disableTitle,
      isPresented: Binding(
        get: { pendingDisable != nil }, set: { if !$0 { pendingDisable = nil } }),
      presenting: pendingDisable
    ) { global in
      Button("Release (downloads again when needed)") {
        setEnabled(global, false, copy: false)
      }
      if canBringBack(global.offloadedBytes) {
        Button("Bring Back to This Mac (\(Format.bytes(global.offloadedBytes)))") {
          setEnabled(global, false, copy: true)
        }
      }
      Button("Cancel", role: .cancel) {}
    } message: { global in
      Text(
        bringBackMessage(
          global.offloadedBytes,
          held: "\(Format.bytes(global.offloadedBytes)) of it is on the drive."))
    }
  }

  // MARK: Sections

  private var explainer: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: IconState.logoSymbolName)
        .font(.system(size: 30))
        .foregroundStyle(.tint)
      VStack(alignment: .leading, spacing: 6) {
        Text("Keep rebuildable folders on \(model.driveName)")
          .font(.title3.weight(.semibold))
        Text(
          "Stowaway moves folders your tools can rebuild or download again, like node_modules, Cargo build output and package caches, onto your external drive once they go idle. They stay mounted where they were, so your tools keep working. When the drive is unplugged, they fall back to this Mac. Your source code never moves."
        )
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
      }
    }
  }

  private var cachesSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader(
        "Shared caches",
        detail:
          "Machine-wide caches that all your projects use. These are the ones found on this Mac.")
      GroupBox {
        if model.detectedGlobals.isEmpty {
          Text(noCachesMessage)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(6)
        } else {
          VStack(spacing: 0) {
            ForEach(Array(model.detectedGlobals.enumerated()), id: \.element.id) { index, global in
              if index > 0 { Divider() }
              cacheRow(global)
            }
          }
        }
      }
      if !model.undetectedGlobals.isEmpty {
        Text(
          "Also supported once installed: "
            + model.undetectedGlobals.map(\.label).joined(separator: ", ") + "."
        )
        .font(.caption)
        .foregroundStyle(.secondary)
      }
    }
  }

  private func cacheRow(_ global: GlobalReport) -> some View {
    HStack(alignment: .firstTextBaseline) {
      Toggle(isOn: enabledBinding(global)) {
        VStack(alignment: .leading, spacing: 2) {
          Text(global.label).fontWeight(.medium)
          Text(global.description).foregroundStyle(.secondary)
          Text(global.paths.map { Format.abbreviatedPath($0) }.joined(separator: ", "))
            .font(.caption)
            .foregroundStyle(.tertiary)
            .lineLimit(1)
            .truncationMode(.middle)
        }
      }
      .toggleStyle(.checkbox)
      .disabled(model.busyMessage != nil || !model.agentReachable)
      Spacer(minLength: 12)
      Text(cacheState(global))
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
    .padding(.vertical, 6)
    .padding(.horizontal, 4)
  }

  private var foldersSection: some View {
    VStack(alignment: .leading, spacing: 8) {
      sectionHeader(
        "Code folders",
        detail:
          "Add the folders that hold your projects, not each project on its own. Stowaway looks inside them for node_modules and Cargo target folders. For example, if ~/code holds your git checkouts, like ~/code/my-app and ~/code/api-server, add ~/code."
      )
      VStack(spacing: 0) {
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
        .frame(minHeight: 120, idealHeight: 150)
        .overlay {
          if roots.isEmpty {
            Text("No code folders yet. Click + to add one, such as ~/code.")
              .foregroundStyle(.secondary)
          }
        }
        Divider()
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
        }
        .buttonStyle(.borderless)
        .padding(6)
      }
      .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
      .clipShape(RoundedRectangle(cornerRadius: 6))
    }
  }

  @ViewBuilder
  private var statusBar: some View {
    HStack(spacing: 6) {
      if let message = model.busyMessage {
        ProgressView().controlSize(.small)
        Text(message).foregroundStyle(.secondary)
      } else if let error = model.lastError {
        Text(error).foregroundStyle(.red).lineLimit(2)
      } else if !model.agentReachable {
        Text("Stowaway isn't running, so changes can't be made right now.")
          .foregroundStyle(.secondary)
      }
      Spacer()
    }
    .font(.caption)
    .padding(.horizontal, 12)
    .padding(.vertical, 8)
  }

  private func sectionHeader(_ title: String, detail: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(title).font(.headline)
      Text(detail)
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
  }

  // MARK: Shared caches

  private var noCachesMessage: String {
    guard model.agentReachable, let status = model.status else {
      return "Start Stowaway to see the caches on this Mac."
    }
    return status.globals == nil
      ? "Update Stowaway to manage shared caches here."
      : "None of the supported caches are on this Mac yet."
  }

  private func cacheState(_ global: GlobalReport) -> String {
    if !global.enabled { return "Off" }
    if global.offloadedBytes > 0 { return "\(Format.bytes(global.offloadedBytes)) offloaded" }
    if let pending = global.pendingBytes, pending > 0 {
      return "\(Format.bytes(pending)) to offload"
    }
    return "Offloads when idle"
  }

  private func enabledBinding(_ global: GlobalReport) -> Binding<Bool> {
    Binding(
      get: { global.enabled },
      set: { enabled in
        if !enabled && global.entries > 0 {
          pendingDisable = global
        } else {
          setEnabled(global, enabled, copy: false)
        }
      })
  }

  private func setEnabled(_ global: GlobalReport, _ enabled: Bool, copy: Bool) {
    Task { await model.setGlobalEnabled(global, enabled: enabled, copy: copy) }
  }

  private var disableTitle: String {
    pendingDisable.map { "Stop offloading the \($0.label)?" } ?? ""
  }

  // MARK: Code folders

  private var addTitle: String {
    pendingAdd.map { "Watch \(Format.abbreviatedPath($0.path))?" } ?? ""
  }

  private var removeTitle: String {
    pendingRemove.map { "Stop watching \(Format.abbreviatedPath($0.path))?" } ?? ""
  }

  private func bringBackMessage(_ bytes: UInt64, held: String) -> String {
    if model.status?.drive.connected != true {
      return "Connect the drive to bring its data back to this Mac."
    }
    if !canBringBack(bytes) {
      return "There isn't enough free space on this Mac to bring \(Format.bytes(bytes)) back."
    }
    return held
  }

  private func canBringBack(_ bytes: UInt64) -> Bool {
    guard model.status?.drive.connected == true else { return false }
    let home = URL(fileURLWithPath: NSHomeDirectory())
    let values = try? home.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
    let free = values?.volumeAvailableCapacityForImportantUsage ?? 0
    return free > Int64(clamping: bytes)
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
    panel.message = "Choose a folder that holds your projects, such as ~/code"
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
