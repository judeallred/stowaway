import Foundation
import StoreKit

/// Purchases. Finding and deleting folders is free, and so is stowing up to `freeOffloadLimit`;
/// any purchase makes stowing unlimited, for good. Bringing stowed folders back and deleting
/// them are never limited. Purchases are pay-what-you-want and come in two groups: personal
/// (Family Sharing on) and business (for people who can expense it; their purchases keep prices
/// low for everyone else). Product IDs name a slot, not a price: prices are set in App Store Connect.
@MainActor @Observable
final class Store {
  enum Audience: String, CaseIterable {
    case personal
    case business
  }

  /// 100 GB, counted the way macOS counts disk space.
  static let freeOffloadLimit: Int64 = 100_000_000_000

  static let productIDs: [Audience: [String]] = [
    .personal: (1...8).map { "com.brooklynspaceport.stowaway.personal.\($0)" },
    .business: (1...11).map { "com.brooklynspaceport.stowaway.business.\($0)" },
  ]

  /// What each personal price says in the app. Business prices show just the amount, except
  /// the top one. App Store Connect's display names are capped at 30
  /// characters, so these live here; the store's short names appear on receipts and invoices.
  static let taglines: [String: String] = [
    "com.brooklynspaceport.stowaway.personal.1": "A sandwich",
    "com.brooklynspaceport.stowaway.personal.2": "A really nice sandwich",
    "com.brooklynspaceport.stowaway.personal.3": "Sandwiches for the whole team",
    "com.brooklynspaceport.stowaway.personal.4": "Dinner for one",
    "com.brooklynspaceport.stowaway.personal.5": "Dinner for the whole team",
    "com.brooklynspaceport.stowaway.personal.6": "Still cheaper than upgrading your storage",
    "com.brooklynspaceport.stowaway.personal.7": "We will send you a hand-written thank you card",
    "com.brooklynspaceport.stowaway.personal.8": "We'll send you a birthday card every year",
    "com.brooklynspaceport.stowaway.business.11": "Enterprise",
  ]

  private(set) var products: [Audience: [Product]] = [:]
  /// Product IDs the user owns (verified, not refunded).
  private(set) var owned: Set<String> = []
  private(set) var loadError: String?
  private(set) var purchasing: String?
  /// Set once entitlements have been read, so a paying user's actions never see the free limit.
  private(set) var loaded = false
  /// The most recent purchase, for the paid invoice.
  private(set) var latestPurchase: PurchaseRecord?
  private var updates: Task<Void, Never>?
  #if DEBUG
    /// Snapshots only: price labels to show when the App Store isn't reachable.
    var demoPrices: [Audience: [(price: String, name: String)]] = [
      .personal: [
        ("$8", "A sandwich"), ("$16", "A really nice sandwich"),
        ("$32", "Sandwiches for the whole team"), ("$64", "Dinner for one"),
        ("$128", "Dinner for the whole team"),
        ("$256", "Still cheaper than upgrading your storage"),
        ("$512", "We will send you a hand-written thank you card"),
        ("$1,024", "We'll send you a birthday card every year"),
      ],
      .business: (1...10).map { ("$\($0 * 50)", "") } + [("$5,000", "Enterprise")],
    ]
  #endif

  /// What an invoice needs to know about a purchase.
  struct PurchaseRecord: Sendable {
    let productID: String
    let price: Decimal
    let currencyCode: String
    let date: Date
    let transactionID: UInt64
  }

  var hasPurchased: Bool { !owned.isEmpty }

  /// The App Store's name for a product, such as "Business Plus".
  func displayName(of productID: String) -> String? {
    products.values.joined().first { $0.id == productID }?.displayName
  }

  /// The limit `Engine.adopt` applies: none once anything's been bought, the free tier otherwise.
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
      let all = try await Product.products(
        for: Self.productIDs.values.flatMap { $0 })
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
    var latest: PurchaseRecord?
    for await entitlement in Transaction.currentEntitlements {
      if case .verified(let transaction) = entitlement, transaction.revocationDate == nil {
        ids.insert(transaction.productID)
        if let price = transaction.price, latest.map({ $0.date < transaction.purchaseDate }) ?? true
        {
          latest = PurchaseRecord(
            productID: transaction.productID, price: price,
            currencyCode: transaction.currency?.identifier ?? "USD",
            date: transaction.purchaseDate, transactionID: transaction.id)
        }
      }
    }
    owned = ids
    latestPurchase = latest
    loaded = true
  }

  /// Waits (briefly) for the first entitlement check.
  func waitUntilLoaded() async {
    for _ in 0..<50 where !loaded {
      try? await Task.sleep(for: .milliseconds(100))
    }
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
