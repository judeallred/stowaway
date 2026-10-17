import AppKit

/// Draws the logo-plus-badge template images for the menu bar. `MenuBarExtra` labels only render
/// a single image, so the logo and badge are composited here rather than stacked in SwiftUI.
@MainActor
enum MenuBarImage {
  private static let canvas = NSSize(width: 20, height: 17)
  private static let logoSize: CGFloat = 17
  private static let badgeConfig = NSImage.SymbolConfiguration(pointSize: 8.5, weight: .bold)
  /// Width of the transparent gap cut around the badge so it reads apart from the logo.
  private static let gap: CGFloat = 1.5

  private static var cache: [String: NSImage] = [:]

  static func image(badge: String?) -> NSImage {
    let key = badge ?? ""
    if let cached = cache[key] { return cached }
    let image = render(badge: badge)
    cache[key] = image
    return image
  }

  private static func render(badge: String?) -> NSImage {
    let logo = Logo.image(size: logoSize)
    let badgeImage = badge.flatMap {
      NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(
        badgeConfig)
    }
    let image = NSImage(size: canvas, flipped: false) { rect in
      logo.draw(
        in: NSRect(
          x: 0, y: rect.maxY - logo.size.height, width: logo.size.width, height: logo.size.height))
      guard let badgeImage else { return true }
      let badgeRect = NSRect(
        x: rect.maxX - badgeImage.size.width, y: 0, width: badgeImage.size.width,
        height: badgeImage.size.height)
      for dx in [-gap, 0, gap] {
        for dy in [-gap, 0, gap] {
          badgeImage.draw(
            in: badgeRect.offsetBy(dx: dx, dy: dy), from: .zero, operation: .destinationOut,
            fraction: 1)
        }
      }
      badgeImage.draw(in: badgeRect)
      return true
    }
    image.isTemplate = true
    return image
  }
}
