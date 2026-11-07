// Рисует AppIcon 1024×1024: тёмный квадрат-«сквиркл» с «островом» и кольцом таймера.
import AppKit

let size: CGFloat = 1024
let out = CommandLine.arguments[1]

let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
    let inset: CGFloat = 100
    let body = NSRect(x: inset, y: inset, width: size - inset * 2, height: size - inset * 2)
    let path = NSBezierPath(roundedRect: body, xRadius: 185, yRadius: 185)

    NSGraphicsContext.current?.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = NSColor.black.withAlphaComponent(0.35)
    shadow.shadowBlurRadius = 24
    shadow.shadowOffset = NSSize(width: 0, height: -10)
    shadow.set()
    NSGradient(starting: NSColor(white: 0.20, alpha: 1), ending: NSColor(white: 0.06, alpha: 1))!.draw(in: path, angle: -90)
    NSGraphicsContext.current?.restoreGraphicsState()

    // «Остров» сверху
    let island = NSRect(x: size / 2 - 150, y: body.maxY - 150, width: 300, height: 74)
    NSColor.black.setFill()
    NSBezierPath(roundedRect: island, xRadius: 37, yRadius: 37).fill()
    NSColor.systemOrange.setFill()
    NSBezierPath(ovalIn: NSRect(x: island.minX + 34, y: island.midY - 13, width: 26, height: 26)).fill()

    // Кольцо таймера
    let center = NSPoint(x: size / 2, y: size / 2 - 50)
    let radius: CGFloat = 210
    let track = NSBezierPath()
    track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
    track.lineWidth = 46
    NSColor(white: 1, alpha: 0.14).setStroke()
    track.stroke()

    let arc = NSBezierPath()
    arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: -150, clockwise: true)
    arc.lineWidth = 46
    arc.lineCapStyle = .round
    NSColor.white.setStroke()
    arc.stroke()

    let hand = NSBezierPath()
    hand.move(to: center)
    hand.line(to: NSPoint(x: center.x, y: center.y + radius - 70))
    hand.lineWidth = 30
    hand.lineCapStyle = .round
    NSColor.systemOrange.setStroke()
    hand.stroke()
    NSColor.white.setFill()
    NSBezierPath(ovalIn: NSRect(x: center.x - 26, y: center.y - 26, width: 52, height: 52)).fill()
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8,
                           samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                           bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
