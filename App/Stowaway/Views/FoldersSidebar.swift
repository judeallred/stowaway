import StowawayCore
import SwiftUI

/// What the Folders window's table shows: every folder found, or those in one watched folder.
enum FolderScope: Hashable {
  case all
  case root(String)
}

/// The Folders window's sidebar: the folders Stowaway looks in (with Add and Remove), and
/// folders it suggests adding.
struct FoldersSidebar: View {
  let model: AppModel
  @Binding var scope: FolderScope?
  @State private var explainingHomeFolder = false

  var body: some View {
    List(selection: $scope) {
      Label("All Folders", systemImage: "tray.full")
        .badge(model.rows.filter { !model.cantStow($0) }.count)
        .tag(FolderScope.all)
      Section("Looks In") {
        ForEach(model.rootGroups, id: \.root) { group in
          RootLabel(
            root: group.root, nested: group.nested,
            detail: Format.count(found(in: group.root), "folder") + " found"
          )
          .tag(FolderScope.root(group.root))
          .contextMenu {
            Button("Show in Finder") {
              NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: group.root)])
            }
            Button("Remove") { remove(group.root) }
          }
        }
      }
      let suggestions = model.folderSuggestions
      if !suggestions.isEmpty {
        Section("Suggested") {
          ForEach(suggestions) { suggestion in
            SuggestionRow(model: model, suggestion: suggestion)
          }
          if suggestions.count > 1, !model.ungrantedCaches.isEmpty {
            Button("Allow All Caches…") { explainingHomeFolder = true }
              .buttonStyle(.link)
              .help("Lets Stowaway see your home folder, which covers every shared cache.")
          }
        }
      }
    }
    .listStyle(.sidebar)
    .safeAreaInset(edge: .bottom) { footer }
    .task { await model.detectProjectFolders() }
    .sheet(isPresented: $explainingHomeFolder) {
      HomeFolderExplainer(
        openPanel: { model.allowHomeFolder() }, back: { explainingHomeFolder = false }
      )
      .padding(24)
      .frame(width: 560, height: 400)
    }
  }

  private var footer: some View {
    VStack(alignment: .leading, spacing: 6) {
      HStack(spacing: 4) {
        Button {
          model.addRoot(startingAt: realHomeDirectory)
        } label: {
          Image(systemName: "plus").frame(width: 16, height: 16)
        }
        .help("Add a folder for Stowaway to look in")
        .accessibilityLabel("Add Folder")
        Button {
          if case .root(let root) = scope { remove(root) }
        } label: {
          Image(systemName: "minus").frame(width: 16, height: 16)
        }
        .disabled(selectedRoot == nil)
        .help("Stop looking in the selected folder (nothing in it is touched)")
        .accessibilityLabel("Remove Folder")
        Spacer()
      }
      .buttonStyle(.borderless)
      Text("To skip a folder inside one of these, put a file named .stowaway-ignore in it.")
        .font(.caption2).foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
    .padding(10)
  }

  private var selectedRoot: String? {
    if case .root(let root) = scope { return root }
    return nil
  }

  private func found(in root: String) -> Int {
    model.rows.filter { !model.cantStow($0) && $0.path.isWithin(root) }.count
  }

  private func remove(_ root: String) {
    model.removeRoot(root)
    if !model.roots.contains(root), scope == .root(root) { scope = .all }
  }
}

/// A folder Stowaway looks in, with any chosen folders inside it ("Includes …").
struct RootLabel: View {
  let root: String
  let nested: [String]
  var detail: String?
  var systemImage = "folder.fill"

  var body: some View {
    Label {
      VStack(alignment: .leading, spacing: 1) {
        Text(Format.path(root)).lineLimit(1).truncationMode(.middle)
        if !nested.isEmpty {
          Text("Includes \(nested.map(Format.path).joined(separator: ", "))")
            .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
        }
        if let detail {
          Text(detail).font(.caption).foregroundStyle(.secondary)
        }
      }
    } icon: {
      Image(systemName: systemImage)
    }
    .help(root)
  }
}

/// A folder Stowaway suggests: Add opens the panel there; the cross stops suggesting it.
private struct SuggestionRow: View {
  let model: AppModel
  let suggestion: AppModel.FolderSuggestion

  var body: some View {
    HStack(spacing: 6) {
      VStack(alignment: .leading, spacing: 1) {
        Text(suggestion.title).lineLimit(1).truncationMode(.middle)
        Text(suggestion.detail).font(.caption).foregroundStyle(.secondary)
          .lineLimit(1).truncationMode(.middle)
      }
      Spacer(minLength: 4)
      Button("Add…") { model.addSuggestion(suggestion) }
        .controlSize(.small)
        .accessibilityLabel("Add \(suggestion.title)")
      Button {
        model.dismissSuggestion(suggestion)
      } label: {
        Image(systemName: "xmark").font(.caption)
      }
      .buttonStyle(.borderless)
      .help("Don't suggest this folder again")
      .accessibilityLabel("Don't suggest \(suggestion.title) again")
    }
    .help(suggestion.folder.path)
  }
}
