import Foundation
import StowawayCore

/// A line in the Folders window's table: one folder, or a repository whose worktrees' folders
/// are listed under it.
struct FolderItem: Identifiable, Hashable {
  let id: String
  /// The folder, for a folder's line; nil for a repository's.
  let row: Row?
  /// A repository's folders (nil for a folder, so it has no disclosure triangle).
  var children: [FolderItem]?

  let name: String
  let detail: String
  let kindLabel: String
  let sortSize: Int64
  let sortDate: Date
  let placeOrder: Int

  init(row: Row) {
    id = row.id
    self.row = row
    children = nil
    name = row.name
    detail = Format.path(row.path)
    kindLabel = row.kind.label
    sortSize = row.sortSize
    sortDate = row.sortDate
    placeOrder = row.placeOrder
  }

  /// A repository's line, summing its folders.
  init(repository: String, name: String, rows: [Row]) {
    id = "repository:" + repository
    row = nil
    children = rows.map(FolderItem.init(row:))
    self.name = name
    let checkouts = Dictionary(grouping: rows) { $0.checkout?.path ?? $0.path }
    let worktrees = checkouts.values.filter { $0.first?.checkout?.isWorktree == true }.count
    let count = Format.count(worktrees, "worktree")
    detail = checkouts.count > worktrees ? "Main checkout and \(count)" : count
    let kinds = Set(rows.map(\.kind))
    kindLabel = kinds.count == 1 ? rows[0].kind.label : "\(kinds.count) kinds"
    sortSize = rows.map(\.sortSize).reduce(0, +)
    sortDate = rows.map(\.sortDate).max() ?? .distantPast
    placeOrder = rows.map(\.placeOrder).min() ?? 0
  }

  /// Every folder on this line: its own, or a repository's.
  var rows: [Row] { row.map { [$0] } ?? (children ?? []).compactMap(\.row) }

  /// Folders, with those of a repository that has worktrees gathered under it. A repository
  /// with a single checkout is left as it is, so most projects look the same as ever.
  static func grouping(_ rows: [Row]) -> [FolderItem] {
    var items: [FolderItem] = []
    let byRepository = Dictionary(grouping: rows) { $0.checkout?.repository }
    for (repository, rows) in byRepository {
      let checkouts = Set(rows.map { $0.checkout?.path })
      if let repository, checkouts.count > 1, let checkout = rows.first?.checkout {
        items.append(
          FolderItem(repository: repository, name: checkout.repositoryName, rows: rows))
      } else {
        items += rows.map(FolderItem.init(row:))
      }
    }
    return items
  }

  /// Sorted the same way at each level.
  static func sorted(
    _ items: [FolderItem], using order: [KeyPathComparator<FolderItem>]
  ) -> [FolderItem] {
    items.map { item in
      var item = item
      item.children = item.children.map { sorted($0, using: order) }
      return item
    }
    .sorted(using: order)
  }
}
