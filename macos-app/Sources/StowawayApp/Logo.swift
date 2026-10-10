import AppKit

/// The Stowaway logo: a lookout with big round eyes peering over the top of a braced crate. The
/// head is solid, with its eyes and a small smile cut out, so it holds up at menu bar size.
/// Drawn from paths on a 24-unit grid so it stays crisp at any size; always a template image.
@MainActor
enum Logo {
  private static let grid: CGFloat = 24
  private static let eyeRadius: CGFloat = 2.8
  /// The eyes are holes cut out of the solid head, a little off the outline's centers.
  private static let eyeHoleRadius: CGFloat = 1.6
  private static let eyeHoles = [NSPoint(x: 6.6, y: 5.3), NSPoint(x: 17.4, y: 5.1)]
  private static let leftEye = NSPoint(x: 6.49, y: 5.2)
  private static let rightEye = NSPoint(x: 17.51, y: 5.2)
  /// Each eye's outline stops where it opens into the head: at this many degrees below the
  /// horizontal toward the top of the head (negative is above it), and at `eyeSide` degrees from
  /// straight right toward the head's side. The wider the span, the wider the join.
  private static let eyeJoin: CGFloat = -8
  private static let eyeSide: CGFloat = 115
  private static let crate = NSRect(x: 3, y: 10.5, width: 18, height: 10.5)

  private static var cache: [CGFloat: NSImage] = [:]

  static func image(size: CGFloat) -> NSImage {
    if let cached = cache[size] {
      return cached
    }
    let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { rect in
      draw(in: rect)
      return true
    }
    image.isTemplate = true
    cache[size] = image
    return image
  }

  /// Draws into a y-down rect. Angles below are y-down too: 90° points straight down.
  private static func draw(in rect: NSRect) {
    let scale = rect.width / grid
    var transform = AffineTransform(translationByX: rect.minX, byY: rect.minY)
    transform.scale(scale)
    NSColor.black.set()

    func stroke(_ path: NSBezierPath, width: CGFloat) {
      path.transform(using: transform)
      path.lineWidth = width * scale
      path.lineCapStyle = .round
      path.lineJoinStyle = .round
      path.stroke()
    }
    func fill(_ path: NSBezierPath) {
      path.transform(using: transform)
      path.fill()
    }

    // The head: one outline running up the left side, around each eye and across the top. The
    // eyes stay open where they meet the head, and the sides disappear behind the crate.
    let crateTop = crate.minY
    let join = eyeJoin * .pi / 180
    let side = eyeSide * .pi / 180
    let leftSide = leftEye.x + eyeRadius * cos(side)
    let rightSide = rightEye.x - eyeRadius * cos(side)
    let leftJoin = NSPoint(
      x: leftEye.x + eyeRadius * cos(join), y: leftEye.y + eyeRadius * sin(join))
    let rightJoin = NSPoint(
      x: rightEye.x - eyeRadius * cos(join), y: rightEye.y + eyeRadius * sin(join))
    let crown = NSPoint(x: 12, y: 4.6)
    let head = NSBezierPath()
    head.move(to: NSPoint(x: leftSide, y: crateTop))
    head.line(to: NSPoint(x: leftSide, y: leftEye.y + eyeRadius * sin(side)))
    head.appendArc(
      withCenter: leftEye, radius: eyeRadius, startAngle: eyeSide, endAngle: eyeJoin,
      clockwise: false)
    // The top of the head, a quadratic curve written as its cubic equivalent.
    head.curve(
      to: rightJoin,
      controlPoint1: NSPoint(
        x: leftJoin.x + (crown.x - leftJoin.x) * 2 / 3,
        y: leftJoin.y + (crown.y - leftJoin.y) * 2 / 3),
      controlPoint2: NSPoint(
        x: rightJoin.x + (crown.x - rightJoin.x) * 2 / 3,
        y: rightJoin.y + (crown.y - rightJoin.y) * 2 / 3))
    head.appendArc(
      withCenter: rightEye, radius: eyeRadius, startAngle: 180 - eyeJoin,
      endAngle: 180 - eyeSide, clockwise: false)
    head.line(to: NSPoint(x: rightSide, y: crateTop))
    // Fill the head (closed along the crate's top edge), then stroke its outline for the rim.
    if let solid = head.copy() as? NSBezierPath {
      solid.close()
      fill(solid)
    }
    stroke(head, width: 1.9)

    // Cut the eyes and the smile out of the head.
    NSGraphicsContext.current?.compositingOperation = .destinationOut
    for hole in eyeHoles {
      fill(
        NSBezierPath(
          ovalIn: NSRect(
            x: hole.x - eyeHoleRadius, y: hole.y - eyeHoleRadius, width: eyeHoleRadius * 2,
            height: eyeHoleRadius * 2)))
    }
    let smile = NSBezierPath()
    smile.move(to: NSPoint(x: 10.3, y: 7.5))
    // A quadratic curve through (12, 9), written as its cubic equivalent.
    smile.curve(
      to: NSPoint(x: 13.7, y: 7.5), controlPoint1: NSPoint(x: 11.43, y: 8.5),
      controlPoint2: NSPoint(x: 12.57, y: 8.5))
    stroke(smile, width: 1.3)
    NSGraphicsContext.current?.compositingOperation = .sourceOver

    stroke(NSBezierPath(roundedRect: crate, xRadius: 1, yRadius: 1), width: 2)
    // The crate's middle slat, a brace in each half.
    let planks = NSBezierPath()
    planks.move(to: NSPoint(x: crate.minX, y: crate.midY))
    planks.line(to: NSPoint(x: crate.maxX, y: crate.midY))
    planks.move(to: NSPoint(x: 6.8, y: crateTop))
    planks.line(to: NSPoint(x: 18.6, y: crate.midY))
    planks.move(to: NSPoint(x: crate.minX, y: crate.maxY))
    planks.line(to: NSPoint(x: 12.3, y: crate.midY))
    stroke(planks, width: 1.7)
  }
}
