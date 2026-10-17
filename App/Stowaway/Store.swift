import Foundation
import StoreKit

/// Purchases. Stowaway is free, with offloading limited to `freeOffloadLimit`; any purchase lifts
/// the limit. Purchases are pay-what-you-want and come in two groups: personal (Family Sharing
/// on) and business (for people who can expense it; their purchases keep Stowaway free for
/// everyone else). Product IDs name a slot, not a price: prices are set in App Store Connect.
@MainActor @Observable
final class Store {
  enum Audience: String, CaseIterable {
    case personal
    case business
  }

  /// 100 GB, counted the way macOS counts disk space.
  static let freeOffloadLimit: Int64 = 100_000_000_000

  static let productIDs: [Audience: [String]] = [
    .personal: (1...3).map { "com.brooklynspaceport.stowaway.personal.\($0)" },
    .business: (1...4).map { "com.brooklynspaceport.stowaway.business.\($0)" },
  ]

  private(set) var products: [Audience: [Product]] = [:]
  /// Product IDs the user owns (verified, not refunded).
  private(set) var owned: Set<String> = []
  private(set) var loadError: String?
  private(set) var purchasing: String?
  private var updates: Task<Void, Never>?

  var hasPurchased: Bool { !owned.isEmpty }
  var ownedAudience: Audience? {
    if owned.contains(where: { $0.contains(".business.") }) { return .business }
    return owned.isEmpty ? nil : .personal
  }

  /// The offload limit to apply: none once anything's been bought.
  var offloadLimit: Int64? { hasPurchased ? nil : Self.freeOffloadLimit }

  func start() {
    updates = Task { [weak self] in
      for await update in Transaction.updates {
        if case .verified(let transaction) = update {
          await transaction.finish()
        }
        await self?.refreshEntitlements()
      }
    }
    Task {
      await refreshEntitlements()
      await loadProducts()
    }
  }

  func loadProducts() async {
    do {
      let all = try await Product.products(for: Self.productIDs.values.flatMap { $0 })
      var grouped: [Audience: [Product]] = [:]
      for audience in Audience.allCases {
        let ids = Self.productIDs[audience] ?? []
        grouped[audience] = all.filter { ids.contains($0.id) }.sorted { $0.price < $1.price }
      }
      products = grouped
      loadError = all.isEmpty ? "The App Store didn't return any purchase options." : nil
    } catch {
      loadError = error.localizedDescription
    }
  }

  func refreshEntitlements() async {
    var ids: Set<String> = []
    for await entitlement in Transaction.currentEntitlements {
      if case .verified(let transaction) = entitlement, transaction.revocationDate == nil {
        ids.insert(transaction.productID)
      }
    }
    owned = ids
  }

  /// Buys a product. Returns true if it went through.
  @discardableResult
  func purchase(_ product: Product) async -> Bool {
    purchasing = product.id
    defer { purchasing = nil }
    do {
      switch try await product.purchase() {
      case .success(.verified(let transaction)):
        await transaction.finish()
        await refreshEntitlements()
        return true
      case .success(.unverified), .pending, .userCancelled:
        return false
      @unknown default:
        return false
      }
    } catch {
      loadError = error.localizedDescription
      return false
    }
  }

  /// Restores purchases made on another Mac or before a reinstall.
  func restore() async {
    do {
      try await AppStore.sync()
    } catch {
      loadError = error.localizedDescription
    }
    await refreshEntitlements()
  }
}
