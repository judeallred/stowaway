import Foundation
import StowawayCore

/// A line in the Folders window's table: one folder, or a repository with worktrees, which opens
/// to its checkouts (the main one and each worktree), each opening to its folders.
struct FolderItem: Identifiable, Hashable {
  let id: String
  /// The folder, for a folder's line; nil for a repository's or a checkout's.
  let row: Row?
  /// What's under a repository or checkout (nil for a folder, so it has no disclosure triangle).
  var children: [FolderItem]?

  let name: String
  let detail: String
  let kindLabel: String
  let sortSize: Int64
  let sortDate: Date
  let placeOrder: Int
  /// Every folder on this line: its own, or all of those under it.
  let rows: [Row]

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
    rows = [row]
  }

  /// A line summing the folders of the lines under it.
  private init(id: String, name: String, detail: String, children: [FolderItem]) {
    self.id = id
    row = nil
    self.children = children
    self.name = name
    self.detail = detail
    rows = children.flatMap(\.rows)
    let kinds = Set(rows.map(\.kind))
    kindLabel = kinds.count == 1 ? rows[0].kind.label : "\(kinds.count) kinds"
    sortSize = rows.map(\.sortSize).reduce(0, +)
    sortDate = rows.map(\.sortDate).max() ?? .distantPast
    placeOrder = rows.map(\.placeOrder).min() ?? 0
  }

  /// Every line's ID, at every level.
  var allIDs: [ID] { [id] + (children ?? []).flatMap(\.allIDs) }

  /// The folders the lines `ids` stand for: a selected repository or checkout stands for all of
  /// its folders.
  func rows(for ids: Set<ID>) -> [Row] {
    ids.contains(id) ? rows : (children ?? []).flatMap { $0.rows(for: ids) }
  }

  /// Folders, with those of a repository that has worktrees gathered under it, by checkout. A
  /// repository with a single checkout is left as it is, so most projects look the same as ever.
  static func grouping(_ rows: [Row]) -> [FolderItem] {
    var items: [FolderItem] = []
    let byRepository = Dictionary(grouping: rows) { $0.checkout?.repository }
    for (repository, rows) in byRepository {
      let byCheckout = Dictionary(grouping: rows) { $0.checkout?.path ?? "" }
      guard let repository, byCheckout.count > 1, let first = rows.first?.checkout else {
        items += rows.map(FolderItem.init(row:))
        continue
      }
      let checkouts = byCheckout.map { path, rows in checkout(path, rows: rows) }
      let worktrees = Format.count(
        byCheckout.count - (byCheckout[repository] == nil ? 0 : 1), "worktree")
      items.append(
        FolderItem(
          id: "repository:" + repository, name: first.repositoryName,
          detail: byCheckout[repository] == nil ? worktrees : "Main checkout and \(worktrees)",
          children: checkouts))
    }
    return items
  }

  /// A checkout's line, or its one folder's line when it has only one.
  private static func checkout(_ path: String, rows: [Row]) -> FolderItem {
    guard rows.count > 1, let checkout = rows.first?.checkout else {
      return FolderItem(row: rows[0])
    }
    let folders = Format.count(rows.count, "folder")
    return FolderItem(
      id: "checkout:" + path, name: (path as NSString).lastPathComponent,
      detail: checkout.isWorktree ? "Worktree · \(folders)" : "Main checkout · \(folders)",
      children: rows.map(FolderItem.init(row:)))
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
