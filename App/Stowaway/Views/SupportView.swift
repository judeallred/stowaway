import StoreKit
import SwiftUI

/// The upgrade sheet: pay what you want, personal or business. Any purchase lifts the free
/// offload limit; business purchases (for people who can expense them) keep Stowaway free for
/// everyone else.
struct SupportView: View {
  let model: AppModel
  let store: Store
  @Environment(\.dismiss) private var dismiss
  @State private var audience: Store.Audience = .personal
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
          horizontal: false, vertical: true)
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
        Link("Terms of Use", destination: Links.termsOfUse)
        Link("Privacy Policy", destination: Links.privacyPolicy)
        Button(store.hasPurchased ? "Done" : "Not Now") { dismiss() }.keyboardShortcut(
          .cancelAction)
      }
      .font(.callout)
    }
    .padding(24)
    .frame(width: 520)
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
      Text(
        "Stowing up to \(Format.bytes(Store.freeOffloadLimit)) is free. Any purchase, at any price, makes it unlimited, for good."
      )
      .foregroundStyle(.secondary)
    }
  }

  private var audienceNote: String {
    switch audience {
    case .personal: "Pay what you want. Shared with your family through Family Sharing."
    case .business:
      "At work and able to expense it? Please choose a business price. Your purchase is what keeps Stowaway free for everyone using it personally."
    }
  }

  @ViewBuilder private var prices: some View {
    let products = store.products[audience] ?? []
    if products.isEmpty, let demo = snapshotPrices {
      HStack(spacing: 10) {
        ForEach(demo, id: \.price) { item in
          Button {
          } label: {
            VStack(spacing: 2) {
              Text(item.price).font(.title3.weight(.semibold))
              Text(item.name).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
          }
          .controlSize(.large)
        }
      }
    } else if products.isEmpty && store.loadError == nil {
      HStack {
        ProgressView().controlSize(.small)
        Text("Loading prices…").foregroundStyle(.secondary)
      }
    } else {
      HStack(spacing: 10) {
        ForEach(products, id: \.id) { product in
          Button {
            Task {
              _ = await store.purchase(product)
            }
          } label: {
            VStack(spacing: 2) {
              Text(product.displayPrice).font(.title3.weight(.semibold))
              Text(product.displayName).font(.caption)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
          }
          .controlSize(.large)
          .disabled(store.purchasing != nil)
        }
      }
    }
  }

  private var thanks: some View {
    VStack(alignment: .leading, spacing: 8) {
      HStack(spacing: 10) {
        Image(systemName: "heart.fill").foregroundStyle(.pink).font(.title2)
        Text("Thank you").font(.title2.weight(.semibold))
      }
      Text(
        store.ownedAudience == .business
          ? "Your business purchase keeps Stowaway free for people using it personally. Stowing is unlimited."
          : "Your purchase means everything to our 3-person team. Stowing is unlimited."
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
