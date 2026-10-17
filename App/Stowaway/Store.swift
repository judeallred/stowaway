import Foundation
import StoreKit

/// Purchases. Finding and deleting folders is free, and so is stowing up to `freeOffloadLimit`.
/// The free 30-day trial lifts the limit for a month, and any purchase lifts it for good.
/// Bringing stowed folders back and deleting them are never limited. (The trial is a free
/// non-consumable named "30-day Trial", the way App Review guideline 3.1.1 describes; its
/// purchase date, signed by the App Store, is when the trial started.) Purchases are pay-what-you-want and come in two groups: personal (Family Sharing
/// on) and business (for people who can expense it; their purchases keep Stowaway free for
/// everyone else). Product IDs name a slot, not a price: prices are set in App Store Connect.
@MainActor @Observable
final class Store {
  enum Audience: String, CaseIterable {
    case personal
    case business
  }

  /// 25 GB, counted the way macOS counts disk space.
  static let freeOffloadLimit: Int64 = 25_000_000_000
  static let trialID = "com.brooklynspaceport.stowaway.trial30"
  static let trialDays = 30

  static let productIDs: [Audience: [String]] = [
    .personal: (1...3).map { "com.brooklynspaceport.stowaway.personal.\($0)" },
    .business: (1...4).map { "com.brooklynspaceport.stowaway.business.\($0)" },
  ]

  private(set) var products: [Audience: [Product]] = [:]
  /// Product IDs the user owns (verified, not refunded).
  private(set) var owned: Set<String> = []
  private(set) var loadError: String?
  private(set) var purchasing: String?
  /// Set once entitlements have been read, so a paying user's actions never see the free limit.
  private(set) var loaded = false
  /// The free trial, from the App Store (nil until loaded).
  private(set) var trialProduct: Product?
  /// When the user started the free trial, if they have.
  private(set) var trialStarted: Date?
  /// The most recent purchase, for the paid invoice.
  private(set) var latestPurchase: PurchaseRecord?
  private var updates: Task<Void, Never>?
  #if DEBUG
    /// Snapshots only: price labels to show when the App Store isn't reachable.
    var demoPrices: [Audience: [(price: String, name: String)]] = [
      .personal: [("$5", "Thanks"), ("$10", "Big Thanks"), ("$20", "Huge Thanks")],
      .business: [("$50", "Business"), ("$100", "Plus"), ("$200", "Pro"), ("$500", "Patron")],
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
  var ownedAudience: Audience? {
    if owned.contains(where: { $0.contains(".business.") }) { return .business }
    return owned.isEmpty ? nil : .personal
  }

  var trialEnds: Date? {
    trialStarted.map { Calendar.current.date(byAdding: .day, value: Self.trialDays, to: $0) ?? $0 }
  }
  var trialActive: Bool { trialEnds.map { $0 > .now } ?? false }
  /// Whole days left in the trial, counting today (nil when it isn't running).
  var trialDaysLeft: Int? {
    guard trialActive, let end = trialEnds else { return nil }
    return max(1, Int((end.timeIntervalSinceNow / 86_400).rounded(.up)))
  }
  /// Whether the free trial can still be started.
  var canStartTrial: Bool { trialStarted == nil && !hasPurchased }

  var trialEnded: Bool { trialStarted != nil && !trialActive }
  /// Whether stowing is unlimited: during the trial, or once anything's been bought.
  var unlimited: Bool { hasPurchased || trialActive }
  /// The limit `Engine.adopt` applies: none when unlimited, the free tier otherwise.
  var offloadLimit: Int64? { unlimited ? nil : Self.freeOffloadLimit }

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
        for: Self.productIDs.values.flatMap { $0 } + [Self.trialID])
      trialProduct = all.first { $0.id == Self.trialID }
      var grouped: [Audience: [Product]] = [:]
      for audience in Audience.allCases {
        let ids = Self.productIDs[audience] ?? []
        grouped[audience] = all.filter { ids.contains($0.id) }.sorted { $0.price < $1.price }
      }
      products = grouped
      loadError = all.count <= 1 ? "The App Store didn't return any purchase options." : nil
    } catch {
      loadError = error.localizedDescription
    }
  }

  func refreshEntitlements() async {
    var ids: Set<String> = []
    var latest: PurchaseRecord?
    var trial: Date?
    for await entitlement in Transaction.currentEntitlements {
      if case .verified(let transaction) = entitlement, transaction.revocationDate == nil {
        if transaction.productID == Self.trialID {
          trial = transaction.purchaseDate
          continue
        }
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
    trialStarted = trial
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

  /// Starts the free trial (a free purchase through the App Store).
  func startTrial() async {
    if trialProduct == nil { await loadProducts() }
    guard let trialProduct else {
      loadError = "The App Store didn't return the free trial. Try again later."
      return
    }
    await purchase(trialProduct)
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
