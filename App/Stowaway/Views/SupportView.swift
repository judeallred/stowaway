import StoreKit
import SwiftUI

/// The upgrade sheet: pay what you want, personal or business. Any purchase lifts the free
/// offload limit; business purchases (for people who can expense them) keep Stowaway free for
/// everyone else.
struct SupportView: View {
  let model: AppModel
  let store: Store
  @Environment(\.dismiss) private var dismiss

  init(model: AppModel, store: Store, audience: Store.Audience = .personal) {
    self.model = model
    self.store = store
    _audience = State(initialValue: audience)
  }
  @State private var audience: Store.Audience
  @State private var showingLetter = false
  @State private var showingInvoice = false
  @State private var redeeming = false

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      if store.hasPurchased {
        thanks
      } else {
        pitch
        Picker("", selection: $audience) {
          Text("For Me").tag(Store.Audience.personal)
          Text("For Work").tag(Store.Audience.business)
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        Text(audienceNote).font(.callout).foregroundStyle(.secondary).fixedSize(
          horizontal: false, vertical: true
        )
        .tint(.accentColor)
        prices
        if audience == .business {
          VStack(alignment: .leading, spacing: 8) {
            Text("Your expense account is the easiest way to support independent software.")
              .font(.callout)
            HStack {
              Button("Letter to Your Boss…") { showingLetter = true }
              Button("Preview Invoice…") { showingInvoice = true }
            }
          }
        }
      }
      if let error = store.loadError {
        HStack {
          Text(error).font(.caption).foregroundStyle(.red)
          Button("Try Again") { Task { await store.loadProducts() } }
            .controlSize(.small)
        }
      }
      Divider()
      HStack {
        Button("Restore Purchases") { Task { await store.restore() } }
        if #available(macOS 15.0, *) {
          Button("Redeem Code…") { redeeming = true }
            .offerCodeRedemption(isPresented: $redeeming) { _ in
              Task { await store.refreshEntitlements() }
            }
        }
        Spacer()
        Button(store.hasPurchased ? "Done" : "Not Now") { dismiss() }.keyboardShortcut(
          .cancelAction)
      }
      .font(.callout)
      HStack(spacing: 14) {
        Link("Terms of Use", destination: Links.termsOfUse)
        Link("Privacy Policy", destination: Links.privacyPolicy)
      }
      .font(.caption)
    }
    .padding(24)
    .frame(width: 560)
    .task { if store.products.isEmpty { await store.loadProducts() } }
    .sheet(isPresented: $showingLetter) { BossLetterView(model: model) }
    .sheet(isPresented: $showingInvoice) { InvoiceView(model: model) }
  }

  private var pitch: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "heart.fill").foregroundStyle(.pink).font(.title2)
        Text("Share the love").font(.title2.weight(.semibold))
      }
      Text(
        "Are we helping you avoid an expensive storage upgrade? Please share the love. We're Brooklyn Spaceport, a 3-person team making creative products, and your purchase would mean everything to us."
      )
      .fixedSize(horizontal: false, vertical: true)
      Text(
        "Stowing up to \(Format.bytes(Store.freeOffloadLimit)) is free. Any purchase, at a price you choose, makes it unlimited, for good."
      )
      .foregroundStyle(.secondary)
    }
  }

  private var audienceNote: String {
    switch audience {
    case .personal: "Pay what you want. Shared with your family through Family Sharing."
    case .business:
      "Every price point here is honestly cheaper than the cost of upgrading your storage. Please support small businesses by picking what fits within your auto-approve expense budget."
    }
  }

  /// One price button's content: the price and what it buys, and the product (nil for the
  /// sample prices snapshots use).
  private struct Price: Identifiable {
    let id: String
    let price: String
    let tagline: String
    let product: Product?
  }

  private var priceList: [Price] {
    let products = store.products[audience] ?? []
    if products.isEmpty, let demo = snapshotPrices {
      return demo.map { Price(id: $0.price, price: $0.price, tagline: $0.name, product: nil) }
    }
    return products.map {
      Price(
        id: $0.id, price: $0.displayPrice, tagline: Store.taglines[$0.id] ?? "",
        product: $0)
    }
  }

  @ViewBuilder private var prices: some View {
    let list = priceList
    if list.isEmpty && store.loadError == nil {
      HStack {
        ProgressView().controlSize(.small)
        Text("Loading prices…").foregroundStyle(.secondary)
      }
    } else if !list.isEmpty {
      if audience == .business {
        Text("I can expense:").font(.callout.weight(.medium))
      }
      // Personal prices have a line each; business prices are just amounts, five to a row.
      LazyVGrid(
        columns: Array(
          repeating: GridItem(.flexible(), spacing: 10), count: audience == .business ? 5 : 2),
        spacing: 10
      ) {
        ForEach(audience == .business ? list.filter { $0.tagline.isEmpty } : list) { item in
          priceButton(item)
        }
      }
      if audience == .business {
        ForEach(list.filter { !$0.tagline.isEmpty }) { item in
          priceButton(item)
        }
      }
    }
  }

  private func priceButton(_ item: Price) -> some View {
    Button {
      if let product = item.product { Task { _ = await store.purchase(product) } }
    } label: {
      VStack(spacing: 2) {
        Text(item.price).font(.title3.weight(.semibold))
        if !item.tagline.isEmpty {
          Text(item.tagline).font(.caption).multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, minHeight: audience == .business ? 36 : 50)
    }
    .controlSize(.large)
    .disabled(store.purchasing != nil)
    .accessibilityLabel(item.tagline.isEmpty ? item.price : "\(item.price): \(item.tagline)")
  }

  private var thanks: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "heart.fill").foregroundStyle(.pink).font(.title2)
        Text("Thank you").font(.title2.weight(.semibold))
      }
      Text(
        store.ownedAudience == .business
          ? "Your business purchase keeps prices low for people using it personally. Stowing is unlimited, for good."
          : "Your purchase means everything to our 3-person team. Stowing is unlimited, for good."
      )
      if store.latestPurchase != nil {
        Button("Paid Invoice…") { showingInvoice = true }
      }
    }
  }

  /// Debug snapshots only: sample prices, since StoreKit has no products outside Xcode's test setup.
  private var snapshotPrices: [(price: String, name: String)]? {
    #if DEBUG
      Snapshots.folder == nil ? nil : store.demoPrices[audience]
    #else
      nil
    #endif
  }
}
