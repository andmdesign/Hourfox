// Рисует AppIcon 1024×1024 из утверждённого вектора Resources/hourfox-icon.svg.
import AppKit

let out = CommandLine.arguments[1]
let svg = try! String(contentsOfFile: "Resources/hourfox-icon.svg", encoding: .utf8)
let size: CGFloat = 1024

func color(_ hex: String, _ alpha: CGFloat = 1) -> CGColor {
    let v = Int(hex.dropFirst(), radix: 16)!
    return CGColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: alpha)
}

/// В векторе только M, L, C и Z.
func parse(_ d: String) -> CGPath {
    let path = CGMutablePath()
    let tokens = d.replacingOccurrences(of: "([MLCZ])", with: " $1 ", options: .regularExpression).split(separator: " ").map(String.init)
    var i = 0, command = ""
    func point() -> CGPoint {
        defer { i += 2 }
        return CGPoint(x: Double(tokens[i])!, y: Double(tokens[i + 1])!)
    }
    while i < tokens.count {
        if ["M", "L", "C", "Z"].contains(tokens[i]) {
            command = tokens[i]
            i += 1
            if command == "Z" { path.closeSubpath() }
            continue
        }
        switch command {
        case "M": path.move(to: point())
        case "L": path.addLine(to: point())
        case "C":
            let a = point(), b = point(), c = point()
            path.addCurve(to: c, control1: a, control2: b)
        default: i += 1
        }
    }
    return path
}

let image = NSImage(size: NSSize(width: size, height: size), flipped: true) { _ in
    let ctx = NSGraphicsContext.current!.cgContext
    // Значок macOS занимает 824 точки из 1024: остальное место для тени.
    let scale = 824.0 / 1096.0
    ctx.translateBy(x: size / 2, y: size / 2)
    ctx.scaleBy(x: scale, y: scale)
    ctx.translateBy(x: -624, y: -631)

    let rect = CGRect(x: 76, y: 82, width: 1096, height: 1098)
    let body = CGPath(roundedRect: rect, cornerWidth: 285, cornerHeight: 285, transform: nil)
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: 14), blur: 40, color: color("#000000", 0.35))
    ctx.addPath(body)
    ctx.setFillColor(color("#F03A1C"))
    ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(body)
    ctx.clip()
    let wash = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: [color("#FF8A2E"), color("#FA5620"), color("#F03A1C"), color("#E81E0C")] as CFArray, locations: [0, 0.32, 0.68, 1])!
    ctx.drawLinearGradient(wash, start: CGPoint(x: 76 + 1096 * 0.35, y: 82), end: CGPoint(x: 76 + 1096 * 0.62, y: 1180), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
    ctx.restoreGState()

    // Светлый край.
    ctx.addPath(CGPath(roundedRect: rect.insetBy(dx: 4, dy: 4), cornerWidth: 281, cornerHeight: 281, transform: nil))
    ctx.setStrokeColor(color("#FFC48A", 0.5))
    ctx.setLineWidth(7)
    ctx.strokePath()

    let pattern = try! NSRegularExpression(pattern: "<path d=\"([^\"]+)\" fill=\"(#[0-9A-Fa-f]{6})\"")
    let matches = pattern.matches(in: svg, range: NSRange(svg.startIndex..., in: svg))
    for (index, match) in matches.enumerated() {
        let d = String(svg[Range(match.range(at: 1), in: svg)!])
        let fill = String(svg[Range(match.range(at: 2), in: svg)!])
        ctx.saveGState()
        // Тень под силуэтом лиса: первый контур в файле.
        if index == 0 { ctx.setShadow(offset: CGSize(width: 0, height: 20), blur: 34, color: color("#6A0C02", 0.6)) }
        ctx.addPath(parse(d))
        ctx.setFillColor(color(fill))
        ctx.fillPath()
        ctx.restoreGState()
    }
    return true
}

let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size), bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
image.draw(in: NSRect(x: 0, y: 0, width: size, height: size))
NSGraphicsContext.restoreGraphicsState()
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: out))
