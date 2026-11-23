import AppKit

enum LogoStyle { case app, mono, color }

/// The logo, drawn in code so the app icon and both tray variants come from one source.
/// .app: full icon with the standard macOS margin; .color: same without margin (tray); .mono: marks only, for a template image.
func drawLogo(_ side: CGFloat, _ style: LogoStyle) -> NSImage {
    NSImage(size: NSSize(width: side, height: side), flipped: true) { _ in
        let inset = style == .app ? side * 100 / 1024 : 0
        let s = side - 2 * inset
        func pt(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: inset + x * s, y: inset + y * s) }
        func circle(_ cx: CGFloat, _ cy: CGFloat, _ r: CGFloat) -> NSBezierPath {
            NSBezierPath(ovalIn: NSRect(x: inset + (cx - r) * s, y: inset + (cy - r) * s, width: 2 * r * s, height: 2 * r * s))
        }
        let mark: NSColor = style == .mono ? .black : .white

        if style != .mono {
            let sq = NSBezierPath(roundedRect: NSRect(x: inset, y: inset, width: s, height: s), xRadius: s * 0.225, yRadius: s * 0.225)
            NSGradient(starting: NSColor(srgbRed: 0.23, green: 0.51, blue: 0.96, alpha: 1),
                       ending: NSColor(srgbRed: 0.49, green: 0.23, blue: 0.93, alpha: 1))?.draw(in: sq, angle: 45)
        }

        let ring = circle(0.45, 0.57, 0.29)
        ring.lineWidth = s * 0.04
        mark.withAlphaComponent(0.5).setStroke()
        ring.stroke()

        let check = NSBezierPath()
        check.move(to: pt(0.17, 0.54))
        check.line(to: pt(0.40, 0.77))
        check.line(to: pt(0.75, 0.375))
        check.lineWidth = s * 0.13
        check.lineCapStyle = .round
        check.lineJoinStyle = .round
        mark.setStroke()
        check.stroke()

        (style == .mono ? NSColor.black : NSColor(srgbRed: 1.0, green: 0.42, blue: 0.0, alpha: 1)).setFill()
        circle(0.82, 0.18, 0.105).fill()
        return true
    }
}

/// `taskradarbar --icon out.png`: 1024px source for the .icns (see build.sh).
func writeIconPNG(_ path: String) {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1024, pixelsHigh: 1024, bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    drawLogo(1024, .app).draw(in: NSRect(x: 0, y: 0, width: 1024, height: 1024))
    NSGraphicsContext.restoreGraphicsState()
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}
