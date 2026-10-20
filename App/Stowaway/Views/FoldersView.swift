import StowawayCore
import SwiftUI

/// The Folders window: every folder Stowaway manages, where it is and how big it is, for the
/// occasional hand: stowing a few now, bringing some back, deleting. (Stowing is automatic; the
/// main window is the dashboard.) Folders Stowaway can't stow, such as pnpm projects, aren't
/// listed.
struct FoldersView: View {
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
      .filter { !model.cantStow($0) }
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

  /// What the row being worked on shows in the Where column.
  private var working: String { "\((model.operation ?? .stowing).verb)…" }

  private var selected: [Row] { model.rows.filter { selection.contains($0.id) } }

  var body: some View {
    VStack(spacing: 0) {
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
        Panels.deleteNote + " Stowed copies on the drive are deleted too."
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
    Button("Select All") { selection = Set(visible.map(\.id)) }
      .disabled(visible.isEmpty || visible.allSatisfy { selection.contains($0.id) })
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

/// Totals and the drive, above the table. Everything is top-aligned with the drive button,
/// which stays in the same place whether or not a drive is chosen.
struct SummaryHeader: View {
  let model: AppModel
  /// The drive column's width: the button, and the bar or explanation under it.
  static let driveWidth: CGFloat = 230

  var body: some View {
    HStack(alignment: .top, spacing: 24) {
      StowedHeadline(model: model)
      Spacer()
      if let plan = model.store.planName {
        PlanBadge(plan: plan) { model.showingSupport = true }
          .padding(.top, 4)
      }
      if let left = model.freeAllowanceLeft {
        VStack(alignment: .leading, spacing: 6) {
          StorageBar(
            segments: [(Store.freeOffloadLimit - left, .accentColor)],
            total: Store.freeOffloadLimit
          )
          .frame(width: 160)
          .padding(.top, 8)
          .accessibilityLabel("Free stowage used")
          Text(
            model.freeStowageFull
              ? "Free stowage is full" : "\(Format.bytes(left)) of free stowage left"
          )
          .font(.caption)
          .foregroundStyle(
            model.freeStowageFull ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary)
          )
          .fixedSize()
          Button("Go Unlimited…") { model.showingSupport = true }
            .buttonStyle(.link).font(.caption)
        }
        // When it's full, a box calls attention to it (drawn outside, so nothing moves).
        .padding(8)
        .background {
          if model.freeStowageFull {
            RoundedRectangle(cornerRadius: 8)
              .fill(.orange.opacity(0.1))
              .strokeBorder(.orange.opacity(0.7), lineWidth: 1)
          }
        }
        .padding(-8)
      }
      VStack(alignment: .leading, spacing: 6) {
        DriveButton(model: model)
        DriveStats(model: model)
      }
      .frame(width: Self.driveWidth)
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
  }
}

/// After a purchase: the logo with a heart, and the plan. Opens the thank-you sheet.
private struct PlanBadge: View {
  let plan: String
  let open: () -> Void

  var body: some View {
    Button(action: open) {
      HStack(spacing: 10) {
        Image(nsImage: Logo.image(size: 30))
          .overlay(alignment: .bottomTrailing) {
            Image(systemName: "heart.fill")
              .font(.system(size: 11))
              .foregroundStyle(.red)
              .shadow(color: .black.opacity(0.3), radius: 1)
              .offset(x: 4, y: 3)
          }
        VStack(alignment: .leading, spacing: 1) {
          Text(plan).font(.callout.weight(.semibold))
          Text("Unlimited stowage").font(.caption).foregroundStyle(.secondary)
        }
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .help("Thank you! Click to see your purchase, or support us again.")
    .accessibilityLabel("Plan: \(plan). Unlimited stowage.")
  }
}

private struct DriveButton: View {
  let model: AppModel

  var body: some View {
    if let name = model.driveName {
      HStack(spacing: 6) {
        Button {
          model.chooseDrive()
        } label: {
          Label(
            name,
            systemImage: model.driveSymbol
          )
          .lineLimit(1)
          .frame(maxWidth: .infinity)
        }
        .help(
          "Stowing on \(model.drivePath.map(Format.path) ?? name)\(model.driveConnected ? "" : " (disconnected)"). Click to choose a different drive."
        )
        Menu {
          Button("Choose a Different Drive…") { model.chooseDrive() }
          Button("Stop Using \(name)…") { model.stopUsingDrive() }
        } label: {
          Image(systemName: "ellipsis")
        }
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Drive options")
      }
      .controlSize(.large)
    } else {
      Button {
        model.chooseDrive()
      } label: {
        Label("Connect External Storage…", systemImage: "externaldrive.badge.plus")
          .lineLimit(1)
          .frame(maxWidth: .infinity)
      }
      .controlSize(.large)
      .help("Choose a drive, or a folder on one, to stow folders on")
    }
  }
}

/// Under the drive button: space on the drive, or, before one is chosen, what it's for.
private struct DriveStats: View {
  let model: AppModel

  var body: some View {
    if model.driveName == nil {
      Text(
        "Keep folders on a drive instead of deleting them. Your tools still find them."
      )
      .font(.caption).foregroundStyle(.secondary)
      .fixedSize(horizontal: false, vertical: true)
    } else if model.driveConnected, let free = model.driveFreeBytes,
      let total = model.driveTotalBytes, total > 0
    {
      VStack(alignment: .trailing, spacing: 3) {
        DriveSpaceBar(model: model, free: free, total: total)
        Text(
          "Stowing \(Format.bytes(model.offloadedBytes)) – \(Format.bytes(free)) free of \(Format.bytes(total))"
        )
        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
      }
    } else if !model.driveConnected {
      Text("Disconnected: your tools use local folders meanwhile.")
        .font(.caption).foregroundStyle(.orange)
        .fixedSize(horizontal: false, vertical: true)
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
      Label("Kept on Mac", systemImage: "pin")
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
