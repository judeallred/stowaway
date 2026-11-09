import StowawayCore
import SwiftUI

/// The Folders window: the folders Stowaway looks in (the sidebar, with suggestions), and every
/// folder it found there, where it is and how big it is, for the occasional hand: stowing a few
/// now, bringing some back, deleting. (Stowing is automatic; the main window is the dashboard.)
/// Folders Stowaway can't stow, such as pnpm projects, aren't listed.
struct FoldersView: View {
  @Bindable var model: AppModel
  @State private var selection: Set<FolderItem.ID> = []
  @State private var filter: Filter = .all
  @State private var sortOrder = [KeyPathComparator(\FolderItem.sortSize, order: .reverse)]
  @State private var confirmingDelete: [Row] = []
  @State private var search = ""
  /// All folders, or those in one watched folder (chosen in the sidebar).
  @State private var scope: FolderScope? = .all

  enum Filter: String, CaseIterable, Identifiable {
    case all = "All"
    case mac = "On This Mac"
    case drive = "Stowed"
    var id: String { rawValue }
  }

  private var visible: [Row] {
    model.rows
      .filter { !model.cantStow($0) }
      .filter {
        guard case .root(let root) = scope else { return true }
        return $0.path.isWithin(root)
      }
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
  }

  /// The table's lines: the visible folders, worktrees gathered under their repository.
  private var items: [FolderItem] {
    FolderItem.sorted(FolderItem.grouping(visible), using: sortOrder)
  }

  /// What the row being worked on shows in the Where column.
  private var working: String { "\((model.operation ?? .stowing).verb)…" }

  /// Selected rows the filter and search still show: hidden ones are never acted on. A selected
  /// repository stands for all its folders.
  private var selected: [Row] { rows(for: selection) }

  private func rows(for ids: Set<FolderItem.ID>) -> [Row] {
    items.flatMap { item in
      ids.contains(item.id) ? item.rows : item.rows.filter { ids.contains($0.id) }
    }
  }

  var body: some View {
    NavigationSplitView {
      FoldersSidebar(model: model, scope: $scope)
        .navigationSplitViewColumnWidth(min: 200, ideal: 230, max: 340)
    } detail: {
      detail
    }
  }

  private var detail: some View {
    VStack(spacing: 0) {
      if model.roots.isEmpty {
        EmptyState.noFolders(
          model,
          detail:
            "Stowaway finds node_modules, build folders and caches in the folders you choose. It can't see anything else."
        )
      } else if model.rows.isEmpty && !model.scanning {
        EmptyState(
          title: "Nothing to tidy up",
          detail: "No re-creatable folders in the folders you've chosen.",
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
        Panels.deleteNote + " Stowed copies on the drive are deleted too."
      )
    }
  }

  private var table: some View {
    Table(items, children: \.children, selection: $selection, sortOrder: $sortOrder) {
      TableColumn("Project", value: \.name) { item in
        VStack(alignment: .leading, spacing: 1) {
          Text(item.name).fontWeight(item.row == nil ? .medium : nil)
          Text(item.detail).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            .truncationMode(.middle)
        }
        .help(item.row?.path ?? "\(item.name): \(item.detail.lowercased())")
      }
      .width(min: 140, ideal: 200)
      TableColumn("What", value: \.kindLabel) { item in
        Text(item.kindLabel).help(item.row?.kind.summary ?? "")
      }
      .width(min: 110, ideal: 140)
      TableColumn("Size", value: \.sortSize) { item in
        Text(item.row?.sizeText ?? Format.bytes(item.sortSize)).monospacedDigit()
      }
      .width(80)
      TableColumn("Last Changed", value: \.sortDate) { item in
        Text(Format.ago(item.row?.lastActivity ?? item.rows.compactMap(\.lastActivity).max()))
      }
      .width(min: 90, ideal: 110)
      TableColumn("Where", value: \.placeOrder) { item in
        if let row = item.row {
          place(of: row)
        } else {
          RepositoryPlace(rows: item.rows)
        }
      }
      .width(min: 100, ideal: 120)
    }
    .contextMenu(forSelectionType: FolderItem.ID.self) { ids in
      actions(for: rows(for: ids))
    }
  }

  @ViewBuilder
  private func place(of row: Row) -> some View {
    if model.busy.contains(row.path) {
      HStack(spacing: 6) {
        ProgressView().controlSize(.small)
        Text(working).foregroundStyle(.secondary)
      }
    } else if model.queued.contains(row.path) {
      Label("Queued", systemImage: "clock").foregroundStyle(.secondary)
    } else {
      PlaceLabel(
        place: row.place, kept: model.keptOnMac.contains(row.path),
        problem: model.problem(for: row))
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
    let kept = rows.filter { model.keptOnMac.contains($0.path) }
    if !rows.isEmpty, kept.count < rows.count {
      Button("Keep on This Mac") { Task { await model.keepOnMac(rows) } }
        .disabled(rows.contains { $0.place != .mac } && !model.driveConnected)
        .help("Stowaway won't stow these automatically. Stowed ones are brought back.")
    }
    if !kept.isEmpty {
      Button("Allow Automatic Stowing") { model.allowAutomaticStowing(kept) }
    }
    if !rows.isEmpty {
      Button("Show in Finder") {
        NSWorkspace.shared.activateFileViewerSelecting(rows.map { URL(fileURLWithPath: $0.path) })
      }
      Divider()
      Button("Delete…", role: .destructive) { confirmingDelete = rows }
      Divider()
    }
    selectionButtons
  }

  @ViewBuilder private var selectionButtons: some View {
    let all = items.flatMap { [$0.id] + ($0.children ?? []).map(\.id) }
    Button("Select All") { selection = Set(all) }
      .disabled(all.isEmpty || all.allSatisfy { selection.contains($0) })
    Button("Select None") { selection = [] }
      .disabled(selection.isEmpty)
  }

  /// Acts on the selection, or on every folder shown when nothing is selected.
  private var actionBar: some View {
    HStack {
      if let activity = model.activity {
        ProgressView().controlSize(.small)
        Text(activity).font(.callout).foregroundStyle(.secondary).lineLimit(1)
          .truncationMode(.middle)
      } else {
        MessageLine(model: model)
      }
      Spacer()
      // Scans run when watched folders change (and hourly); ⌘R looks again now.
      Button("Scan Again") { Task { await model.scan() } }
        .keyboardShortcut("r", modifiers: .command)
        .disabled(model.scanning)
        .hidden()
        .frame(width: 0)
      let all = selection.isEmpty
      let rows = all ? visible : selected
      let onMac = rows.filter { $0.place == .mac }
      let offloaded = rows.filter { $0.place != .mac }
      selectionButtons
      Divider().frame(height: 16)
      Button(all ? "Delete All…" : "Delete…", role: .destructive) { confirmingDelete = rows }
        .disabled(rows.isEmpty)
        .help(all ? "Delete every folder shown" : "Delete the selected folders")
      Button(all ? "Bring All Back" : "Bring Back") {
        Task { await model.bringBack(offloaded) }
      }
      .disabled(offloaded.isEmpty || !model.driveConnected)
      // Stowing is automatic; this stows a selection now. There's no Stow All.
      Button("Stow") { Task { await model.offload(onMac) } }
        .disabled(all || onMac.isEmpty || !model.driveConnected)
        .help(
          all
            ? "Select folders to stow them now; the rest are stowed automatically."
            : model.driveConnected ? "" : "Connect your drive first"
        )
        .keyboardShortcut(.defaultAction)
    }
    .padding(10)
  }

  private var deleteTitle: String {
    let bytes = confirmingDelete.map { ($0.localBytes ?? 0) + $0.driveBytes }.reduce(0, +)
    return confirmingDelete.count == 1
      ? "Delete \(confirmingDelete[0].kind.label) in \(confirmingDelete[0].name) (\(Format.bytes(bytes)))?"
      : "Delete \(confirmingDelete.count) folders (\(Format.bytes(bytes)))?"
  }

}

/// Where a repository's folders are: all on the drive, all on this Mac, or how many are stowed.
private struct RepositoryPlace: View {
  let rows: [Row]

  var body: some View {
    let stowed = rows.filter { $0.place != .mac }.count
    if stowed == rows.count {
      Label("Drive", systemImage: "externaldrive.fill")
    } else if stowed == 0 {
      Label("This Mac", systemImage: "laptopcomputer").foregroundStyle(.secondary)
    } else {
      Text("\(stowed) of \(rows.count) stowed").foregroundStyle(.secondary)
    }
  }
}

/// Where a folder is: on the drive or on this Mac. A folder on this Mac is pending; if it's
/// taking a while (a tool is using it, or the last try failed), the reason is in the tooltip.
private struct PlaceLabel: View {
  let place: Row.Place
  /// Chosen to stay on this Mac: automatic stowing leaves it here.
  let kept: Bool
  /// Why it isn't stowed yet, if there's a reason to give.
  let problem: AppModel.Problem?

  var body: some View {
    switch place {
    case .mac where kept:
      Label("Kept on This Mac", systemImage: "pin")
        .foregroundStyle(.secondary)
        .help(
          "You chose to keep this on your Mac, so it isn't stowed automatically. Stow it, or choose Allow Automatic Stowing, to undo that."
        )
    case .mac:
      Label("This Mac", systemImage: "laptopcomputer").foregroundStyle(.secondary)
        .help(problem?.reason ?? "Waiting to be stowed.")
    case .drive: Label("Drive", systemImage: "externaldrive.fill")
    case .driveAway:
      Label("Drive (away)", systemImage: "externaldrive.badge.xmark")
        .foregroundStyle(.orange)
        .help("The drive is disconnected, so your tools are using a local folder meanwhile.")
    }
  }
}
