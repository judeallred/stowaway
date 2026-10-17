import StowawayCore
import SwiftUI

/// The main window: every re-creatable folder Stowaway found, where it is and how big it is,
/// with actions to offload it, bring it back or delete it.
struct LibraryView: View {
  @Bindable var model: AppModel
  @State private var selection: Set<Row.ID> = []
  @State private var filter: Filter = .all
  @State private var sortOrder = [KeyPathComparator(\Row.sortSize, order: .reverse)]
  @State private var confirmingDelete: [Row] = []
  @State private var search = ""

  enum Filter: String, CaseIterable, Identifiable {
    case all = "All"
    case mac = "On This Mac"
    case drive = "Stowed"
    var id: String { rawValue }
  }

  private var visible: [Row] {
    model.rows
      .filter {
        switch filter {
        case .all: true
        case .mac: $0.place == .mac
        case .drive: $0.place != .mac
        }
      }
      .filter {
        search.isEmpty || $0.path.localizedCaseInsensitiveContains(search)
          || $0.kind.label.localizedCaseInsensitiveContains(search)
      }
      .sorted(using: sortOrder)
  }

  private var selected: [Row] { model.rows.filter { selection.contains($0.id) } }

  var body: some View {
    VStack(spacing: 0) {
      SummaryHeader(model: model)
      Divider()
      if model.roots.isEmpty {
        emptyState(
          "Choose the folders Stowaway looks in",
          "Stowaway finds node_modules, build folders and caches in the folders you choose. It can't see anything else.",
          button: "Choose a Folder…"
        ) { model.addRoot() }
        .overlay(alignment: .bottom) {
          Button("Or Create a Sample Project to Try It…") { model.createSampleProject() }
            .buttonStyle(.link)
            .padding(.bottom, 40)
        }
      } else if model.rows.isEmpty && !model.scanning {
        emptyState(
          "Nothing to tidy up", "No re-creatable folders in the folders you've chosen.",
          button: "Scan Again"
        ) {
          Task { await model.scan() }
        }
      } else {
        table
      }
      Divider()
      actionBar
    }
    .searchable(text: $search, placement: .toolbar, prompt: "Filter")
    .toolbar {
      ToolbarItem(placement: .navigation) {
        Picker("Show", selection: $filter) {
          ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
      }
      ToolbarItem {
        SettingsLink {
          Label("Settings", systemImage: "gearshape")
        }
        .help("Settings")
      }
    }
    .confirmationDialog(
      deleteTitle,
      isPresented: Binding(
        get: { !confirmingDelete.isEmpty }, set: { if !$0 { confirmingDelete = [] } }),
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        let rows = confirmingDelete
        Task { await model.delete(rows) }
      }
    } message: {
      Text(
        "These folders are re-created by your tools (npm install, cargo build, Xcode…), which takes time and may need the network. Stowed copies on the drive are deleted too."
      )
    }
  }

  private var table: some View {
    Table(visible, selection: $selection, sortOrder: $sortOrder) {
      TableColumn("Project", value: \.name) { row in
        VStack(alignment: .leading, spacing: 1) {
          Text(row.name)
          Text(Format.path(row.path)).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .truncationMode(.middle)
        }
        .help(row.path)
      }
      TableColumn("What", value: \.kind.label) { row in
        Text(row.kind.label).help(row.kind.summary)
      }
      .width(min: 120, ideal: 150)
      TableColumn("Size", value: \.sortSize) { row in
        Text(row.sizeText).monospacedDigit()
      }
      .width(80)
      TableColumn("Last Changed", value: \.sortDate) { row in
        Text(Format.ago(row.lastActivity))
      }
      .width(min: 90, ideal: 120)
      TableColumn("Where", value: \.placeOrder) { row in
        if model.busy.contains(row.path) {
          ProgressView().controlSize(.small)
        } else {
          PlaceLabel(place: row.place)
        }
      }
      .width(min: 110, ideal: 130)
    }
    .contextMenu(forSelectionType: Row.ID.self) { ids in
      let rows = model.rows.filter { ids.contains($0.id) }
      actions(for: rows)
    }
  }

  @ViewBuilder
  private func actions(for rows: [Row]) -> some View {
    if rows.contains(where: { $0.place == .mac }) {
      Button("Stow on Drive") {
        Task { await model.offload(rows.filter { $0.place == .mac }) }
      }
      .disabled(!model.driveConnected)
    }
    if rows.contains(where: { $0.place != .mac }) {
      Button("Bring Back to Mac") {
        Task { await model.bringBack(rows.filter { $0.place != .mac }) }
      }
      .disabled(!model.driveConnected)
    }
    Button("Show in Finder") {
      NSWorkspace.shared.activateFileViewerSelecting(rows.map { URL(fileURLWithPath: $0.path) })
    }
    Divider()
    Button("Delete…", role: .destructive) { confirmingDelete = rows }
  }

  /// Acts on the selection, or on every folder shown when nothing is selected.
  private var actionBar: some View {
    HStack {
      if let activity = model.activity {
        ProgressView().controlSize(.small)
        Text(activity).font(.callout).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.middle)
      } else if let message = model.message {
        Label(message, systemImage: "exclamationmark.triangle")
          .font(.callout).foregroundStyle(.orange).lineLimit(2)
      }
      Spacer()
      // Scanning runs on its own every couple of minutes; ⌘R looks again now.
      Button("Scan Again") { Task { await model.scan() } }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.scanning)
        .hidden()
        .frame(width: 0)
      let all = selection.isEmpty
      let rows = all ? visible : selected
      let onMac = rows.filter { $0.place == .mac }
      let offloaded = rows.filter { $0.place != .mac }
      Button(all ? "Delete All…" : "Delete…", role: .destructive) { confirmingDelete = rows }
        .disabled(rows.isEmpty)
        .help(all ? "Delete every folder shown" : "Delete the selected folders")
      Button(all ? "Bring All Back" : "Bring Back") {
        Task { await model.bringBack(offloaded) }
      }
      .disabled(offloaded.isEmpty || !model.driveConnected)
      let offload = Button(all ? "Stow All" : "Stow") {
        Task { await model.offload(onMac) }
      }
      .disabled(onMac.isEmpty || !model.driveConnected)
      .help(model.driveConnected ? "" : "Connect your drive first")
      // Return offloads a selection, never everything.
      if all { offload } else { offload.keyboardShortcut(.defaultAction) }
    }
    .padding(10)
  }

  private var deleteTitle: String {
    let bytes = confirmingDelete.map { ($0.localBytes ?? 0) + $0.driveBytes }.reduce(0, +)
    return confirmingDelete.count == 1
      ? "Delete \(confirmingDelete[0].kind.label) in \(confirmingDelete[0].name) (\(Format.bytes(bytes)))?"
      : "Delete \(confirmingDelete.count) folders (\(Format.bytes(bytes)))?"
  }

  private func emptyState(
    _ title: String, _ detail: String, button: String, action: @escaping () -> Void
  ) -> some View {
    VStack(spacing: 12) {
      Spacer()
      Image(nsImage: Logo.image(size: 48)).opacity(0.6)
      Text(title).font(.title3.weight(.semibold))
      Text(detail).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 420)
      Button(button, action: action).controlSize(.large)
      Spacer()
    }
    .frame(maxWidth: .infinity)
  }
}

/// Totals and the offload location, above the table.
private struct SummaryHeader: View {
  let model: AppModel

  var body: some View {
    HStack(alignment: .center, spacing: 24) {
      stat(Format.bytes(model.reclaimableBytes), "re-creatable on this Mac")
      stat(Format.bytes(model.offloadedBytes), "stowed")
      Spacer()
      if let left = model.freeAllowanceLeft {
        VStack(alignment: .trailing, spacing: 4) {
          ProgressView(
            value: Double(Store.freeOffloadLimit - left), total: Double(Store.freeOffloadLimit)
          )
          .frame(width: 160)
          HStack(spacing: 6) {
            Text("\(Format.bytes(left)) of free stowing left").font(.caption).foregroundStyle(
              .secondary)
            Button("Go Unlimited") { model.showingSupport = true }
              .buttonStyle(.link).font(.caption)
          }
        }
      }
      VStack(alignment: .trailing, spacing: 4) {
        DriveButton(model: model)
        DriveStats(model: model)
      }
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }

  private func stat(_ value: String, _ label: String) -> some View {
    VStack(alignment: .leading, spacing: 2) {
      Text(value).font(.title2.weight(.semibold)).monospacedDigit()
      Text(label).font(.caption).foregroundStyle(.secondary)
    }
  }
}

private struct DriveButton: View {
  let model: AppModel

  var body: some View {
    Button {
      model.chooseDrive()
    } label: {
      if let name = model.driveName {
        Label(
          name,
          systemImage: model.driveConnected ? "externaldrive.fill" : "externaldrive.badge.xmark")
      } else {
        Label("Choose Stow Location…", systemImage: "externaldrive.badge.plus")
      }
    }
    .help(
      model.driveName.map {
        "Stowing on \(model.drivePath.map(Format.path) ?? $0)\(model.driveConnected ? "" : " (disconnected)")"
      } ?? "")
  }
}

/// Space on the offload drive, under its button.
private struct DriveStats: View {
  let model: AppModel

  var body: some View {
    if model.driveName != nil {
      if model.driveConnected, let free = model.driveFreeBytes, let total = model.driveTotalBytes,
        total > 0
      {
        VStack(alignment: .trailing, spacing: 3) {
          ProgressView(value: Double(total - free), total: Double(total))
            .frame(width: 160)
            .accessibilityLabel("Drive space used")
          Text("\(Format.bytes(free)) free of \(Format.bytes(total))")
            .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        }
      } else if !model.driveConnected {
        Text("Disconnected: your tools use local folders meanwhile")
          .font(.caption).foregroundStyle(.orange)
      }
    }
  }
}

private struct PlaceLabel: View {
  let place: Row.Place

  var body: some View {
    switch place {
    case .mac: Label("This Mac", systemImage: "laptopcomputer").foregroundStyle(.secondary)
    case .drive: Label("Drive", systemImage: "externaldrive.fill")
    case .driveAway:
      Label("Drive (away)", systemImage: "externaldrive.badge.xmark")
        .foregroundStyle(.orange)
        .help("The drive is disconnected, so your tools are using a local folder meanwhile.")
    }
  }
}

extension Row {
  var sortSize: Int64 { (localBytes ?? 0) + driveBytes }
  var sortDate: Date { lastActivity ?? .distantPast }
  var placeOrder: Int {
    switch place {
    case .mac: 0
    case .drive: 1
    case .driveAway: 2
    }
  }
  var sizeText: String {
    switch place {
    case .mac: localBytes.map(Format.bytes) ?? "…"
    case .drive, .driveAway: Format.bytes(driveBytes)
    }
  }
}
