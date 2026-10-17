import AppKit
import StoreKit
import SwiftUI
import UniformTypeIdentifiers

/// Helps someone expense a business purchase: a letter to send their manager, and an invoice
/// for expense software (a preview before buying, marked paid after).

// MARK: Letter to your boss

struct BossLetterView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @State private var text: String

  init(model: AppModel) {
    self.model = model
    _text = State(initialValue: Self.letter(model: model))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      Text("Letter to your boss").font(.title2.weight(.semibold))
      Text("Edit it as you like, then copy it into an email or save it as a PDF.")
        .foregroundStyle(.secondary)
      TextEditor(text: $text)
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(8)
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 6))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(.separator))
      HStack {
        Button("Copy") {
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(text, forType: .string)
        }
        Button("Save PDF…") {
          PDF.save(LetterPage(text: text), name: "Stowaway purchase request.pdf")
        }
        Spacer()
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 560, height: 520)
  }

  /// The starting text, with this Mac's numbers and the lowest business price.
  static func letter(model: AppModel) -> String {
    let price = model.store.products[.business]?.first?.displayPrice
    var numbers: [String] = []
    if model.reclaimableBytes > 0 {
      numbers.append(
        "On my Mac right now, it has found \(Format.bytes(model.reclaimableBytes)) of folders that can be re-created."
      )
    }
    if model.offloadedBytes > 0 {
      numbers.append(
        "It's already keeping \(Format.bytes(model.offloadedBytes)) on an external drive instead of my Mac's internal one."
      )
    }
    return """
      Hi,

      I'd like to expense Stowaway, a Mac app that keeps the bulky folders development tools \
      create (node_modules, build output, package caches) on an external drive instead of my \
      Mac's internal one, and deletes the ones that can be rebuilt. My tools keep working as \
      before, and nothing in my source code is touched.

      Why it's worth it:
      • A Mac's internal storage can't be upgraded later. Getting more means a new Mac, and \
      choosing more storage when buying one costs hundreds of dollars.
      • An external drive costs far less, and Stowaway makes it work like internal storage for \
      these folders.\(numbers.isEmpty ? "" : "\n• " + numbers.joined(separator: " "))
      • \(price.map { "It's a one-time purchase, from \($0)" } ?? "It's a one-time purchase"), \
      with no subscription, bought through the Mac App Store.

      Stowaway is made by Brooklyn Spaceport, a small independent team. Business purchases \
      also keep it free for people using it personally. More at \(Links.website.absoluteString)

      Thanks,
      """
  }
}

/// The letter laid out on a US Letter page, for the PDF.
private struct LetterPage: View {
  let text: String

  var body: some View {
    Text(text)
      .font(.system(size: 11.5))
      .lineSpacing(3)
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .padding(72)
      .foregroundStyle(.black)
      .background(.white)
      .environment(\.colorScheme, .light)
  }
}

// MARK: Invoice

/// What goes on an invoice. Before a purchase it's a preview of a business price; after, it
/// shows what was actually paid.
struct Invoice {
  enum Status { case preview, paid }

  var status: Status
  var item: String
  var amount: String
  var date: Date
  var number: String
  var billTo: String
  var payment: String
}

struct InvoiceView: View {
  let model: AppModel
  @Environment(\.dismiss) private var dismiss
  @AppStorage("invoiceBillTo") private var billTo = ""
  @State private var tier = 0

  var body: some View {
    let invoice = current
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(invoice.status == .paid ? "Paid invoice" : "Preview invoice")
          .font(.title2.weight(.semibold))
        Spacer()
        if invoice.status == .preview && businessPrices.count > 1 {
          Picker("Price", selection: $tier) {
            ForEach(businessPrices.indices, id: \.self) { i in
              Text("\(businessPrices[i].name) (\(businessPrices[i].price))").tag(i)
            }
          }
          .fixedSize()
        }
      }
      TextField("Bill to: your name and company", text: $billTo, axis: .vertical)
        .lineLimit(1...3)
      InvoicePage(invoice: invoice)
        .frame(width: 612 * 0.7, height: 792 * 0.7)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(radius: 4, y: 2)
        .frame(maxWidth: .infinity)
      HStack {
        Text(
          "Bought through the Mac App Store, so Apple's receipt is the official record of payment; this invoice is for your expense report."
        )
        .font(.caption).foregroundStyle(.secondary)
        Spacer()
        Button("Save PDF…") {
          PDF.save(InvoicePage(invoice: invoice), name: "Stowaway invoice \(invoice.number).pdf")
        }
        Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
      }
    }
    .padding(20)
    .frame(width: 560)
  }

  /// Business tiers to preview, from the App Store (or sample prices in snapshots).
  private var businessPrices: [(name: String, price: String)] {
    let products = model.store.products[.business] ?? []
    if !products.isEmpty { return products.map { ($0.displayName, $0.displayPrice) } }
    #if DEBUG
      return (model.store.demoPrices[.business] ?? []).map { (name: $0.name, price: $0.price) }
    #else
      return []
    #endif
  }

  private var current: Invoice {
    let to = billTo.isEmpty ? "Your name and company" : billTo
    if let purchase = model.store.latestPurchase {
      let name = model.store.displayName(of: purchase.productID) ?? "License"
      return Invoice(
        status: .paid,
        item: "Stowaway for Mac: \(name). One-time purchase, unlimited stowing.",
        amount: purchase.price.formatted(.currency(code: purchase.currencyCode)),
        date: purchase.date,
        number: "SW-\(purchase.transactionID)",
        billTo: to,
        payment:
          "Paid \(purchase.date.formatted(date: .long, time: .omitted)) through the Mac App Store (transaction \(purchase.transactionID))."
      )
    }
    let prices = businessPrices
    let chosen = prices.indices.contains(tier) ? prices[tier] : nil
    return Invoice(
      status: .preview,
      item:
        "Stowaway for Mac: \(chosen?.name ?? "Business"). One-time purchase, unlimited stowing.",
      amount: chosen?.price ?? "—",
      date: .now,
      number: "PREVIEW",
      billTo: to,
      payment: "Payable in Stowaway through the Mac App Store: Support Stowaway → For Work.")
  }
}

/// The invoice laid out on a US Letter page (612 × 792 points), shown scaled in the sheet and
/// saved full size as a PDF.
struct InvoicePage: View {
  let invoice: Invoice

  var body: some View {
    GeometryReader { geometry in
      let scale = geometry.size.width / 612
      page
        .frame(width: 612, height: 792)
        .scaleEffect(scale, anchor: .topLeading)
    }
    .aspectRatio(612 / 792, contentMode: .fit)
  }

  private var page: some View {
    VStack(alignment: .leading, spacing: 28) {
      HStack(alignment: .top) {
        HStack(spacing: 10) {
          Image(nsImage: Logo.image(size: 36))
          VStack(alignment: .leading, spacing: 2) {
            Text("Brooklyn Spaceport").font(.system(size: 16, weight: .semibold))
            Text(Links.website.absoluteString).font(.system(size: 10)).foregroundStyle(.gray)
          }
        }
        Spacer()
        VStack(alignment: .trailing, spacing: 3) {
          Text("INVOICE").font(.system(size: 22, weight: .bold)).kerning(2)
          Text("No. \(invoice.number)").font(.system(size: 10))
          Text(invoice.date.formatted(date: .long, time: .omitted)).font(.system(size: 10))
        }
      }
      VStack(alignment: .leading, spacing: 4) {
        Text("BILL TO").font(.system(size: 9, weight: .semibold)).foregroundStyle(.gray)
        Text(invoice.billTo).font(.system(size: 11))
      }
      VStack(spacing: 0) {
        row("Description", "Qty", "Amount", header: true)
        Divider().overlay(.black)
        row(invoice.item, "1", invoice.amount)
        Divider()
        HStack {
          Spacer()
          Text("Total").font(.system(size: 12, weight: .semibold))
          Text(invoice.amount).font(.system(size: 12, weight: .semibold)).frame(
            width: 90, alignment: .trailing)
        }
        .padding(.vertical, 10)
      }
      VStack(alignment: .leading, spacing: 6) {
        Text("PAYMENT").font(.system(size: 9, weight: .semibold)).foregroundStyle(.gray)
        Text(invoice.payment).font(.system(size: 10.5))
      }
      Spacer()
      Text(
        "Sold through the Mac App Store, which collects payment and any applicable tax. Apple's receipt, in your Apple Account's purchase history, is the official record of payment. Business purchases keep Stowaway free for people using it personally. Thank you."
      )
      .font(.system(size: 9)).foregroundStyle(.gray)
    }
    .padding(56)
    .frame(width: 612, height: 792, alignment: .topLeading)
    .foregroundStyle(.black)
    .background(.white)
    .overlay { watermark }
    .environment(\.colorScheme, .light)
  }

  private var watermark: some View {
    Text(invoice.status == .paid ? "PAID" : "PREVIEW")
      .font(.system(size: 110, weight: .heavy))
      .kerning(8)
      .foregroundStyle(invoice.status == .paid ? Color.green : Color.gray)
      .opacity(0.14)
      .rotationEffect(.degrees(-30))
      .accessibilityHidden(true)
  }

  private func row(_ a: String, _ b: String, _ c: String, header: Bool = false) -> some View {
    HStack(alignment: .top) {
      Text(a).frame(maxWidth: .infinity, alignment: .leading)
      Text(b).frame(width: 40, alignment: .trailing)
      Text(c).frame(width: 90, alignment: .trailing)
    }
    .font(.system(size: header ? 9 : 11, weight: header ? .semibold : .regular))
    .foregroundStyle(header ? .gray : .black)
    .padding(.vertical, 8)
  }
}

// MARK: PDF

@MainActor
enum PDF {
  /// Renders `view` onto a US Letter page and saves it where the user chooses.
  static func save(_ view: some View, name: String) {
    let panel = NSSavePanel()
    panel.nameFieldStringValue = name
    panel.allowedContentTypes = [.pdf]
    NSApp.activate()
    guard panel.runModal() == .OK, let url = panel.url else { return }
    let size = CGSize(width: 612, height: 792)
    let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height))
    renderer.render { _, draw in
      var box = CGRect(origin: .zero, size: size)
      guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { return }
      context.beginPDFPage(nil)
      draw(context)
      context.endPDFPage()
      context.closePDF()
    }
  }
}
