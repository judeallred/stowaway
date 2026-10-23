// Renders the app icon from the logo: the lookout in white on a rounded-square gradient, on
// Apple's macOS icon grid (an 824-point shape in a 1024-point canvas).
//
// Usage: swiftc -swift-version 5 -parse-as-library -o make-icon App/scripts/make-icon.swift \
//          App/Stowaway/Branding/Logo.swift && ./make-icon App/Stowaway/Resources/Assets.xcassets/AppIcon.appiconset
import AppKit

@MainActor
func render(size: CGFloat) -> NSBitmapImageRep {
  guard
    let rep = NSBitmapImageRep(
      bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
      samplesPerPixel: 4,
      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
    let context = NSGraphicsContext(bitmapImageRep: rep)
  else { fatalError("can't make a bitmap") }
  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = context
  let scale = size / 1024
  let shape = NSRect(x: 100 * scale, y: 100 * scale, width: 824 * scale, height: 824 * scale)
  let path = NSBezierPath(roundedRect: shape, xRadius: 185 * scale, yRadius: 185 * scale)

  // A soft drop shadow under the shape, as macOS icons have.
  NSGraphicsContext.saveGraphicsState()
  let shadow = NSShadow()
  shadow.shadowColor = NSColor.black.withAlphaComponent(0.3)
  shadow.shadowBlurRadius = 18 * scale
  shadow.shadowOffset = NSSize(width: 0, height: -8 * scale)
  shadow.set()
  NSColor(calibratedRed: 0.09, green: 0.16, blue: 0.29, alpha: 1).setFill()
  path.fill()
  NSGraphicsContext.restoreGraphicsState()

  // Deep night-sky blue to teal, like a lookout's view at dusk.
  let gradient = NSGradient(colors: [
    NSColor(calibratedRed: 0.07, green: 0.13, blue: 0.27, alpha: 1),
    NSColor(calibratedRed: 0.05, green: 0.42, blue: 0.52, alpha: 1),
  ])
  gradient?.draw(in: path, angle: 90)

  // The logo, tinted white, centered with room around it.
  let logoSize = 560 * scale
  let logo = Logo.image(size: logoSize)
  let tinted = NSImage(size: logo.size, flipped: false) { rect in
    logo.draw(in: rect)
    NSColor.white.set()
    rect.fill(using: .sourceAtop)
    return true
  }
  tinted.draw(
    in: NSRect(
      x: (size - logoSize) / 2, y: (size - logoSize) / 2 - 10 * scale, width: logoSize,
      height: logoSize))
  NSGraphicsContext.restoreGraphicsState()
  return rep
}

@main
enum MakeIcon {
  @MainActor
  static func main() {
    guard CommandLine.arguments.count == 2 else {
      print("usage: make-icon <AppIcon.appiconset>")
      exit(2)
    }
    let folder = URL(fileURLWithPath: CommandLine.arguments[1])
    try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var images: [[String: String]] = []
    for points in [16, 32, 128, 256, 512] {
      for scale in [1, 2] {
        let pixels = points * scale
        let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
        guard let png = render(size: CGFloat(pixels)).representation(using: .png, properties: [:])
        else { continue }
        do {
          try png.write(to: folder.appendingPathComponent(name))
        } catch {
          print("couldn't write \(name): \(error)")
          exit(1)
        }
        images.append([
          "idiom": "mac", "size": "\(points)x\(points)", "scale": "\(scale)x", "filename": name,
        ])
      }
    }
    let contents: [String: Any] = ["images": images, "info": ["author": "xcode", "version": 1]]
    do {
      let data = try JSONSerialization.data(
        withJSONObject: contents, options: [.prettyPrinted, .sortedKeys])
      try data.write(to: folder.appendingPathComponent("Contents.json"))
    } catch {
      print("couldn't write Contents.json: \(error)")
      exit(1)
    }
    print("wrote \(images.count) icons to \(folder.path)")
  }
}
