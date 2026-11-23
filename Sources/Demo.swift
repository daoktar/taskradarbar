import SwiftUI
import AppKit

/// `taskradarbar --screenshots docs`: renders the README pictures from made-up tasks.
/// Nothing is captured from the screen, no real note is read, the user's settings are not touched:
/// the window content is drawn offscreen and framed with a drawn menu bar and popover.
func writeDemoScreenshot(_ path: String, expanded: String?, lang: String = "en") {
    let d = { (n: Int) in day(addDays(n)) }
    let note = """
    ## Today
    ```tasks
    not done
    (due on today) OR (scheduled today)
    ```
    ## Today - meetings
    **10:00 - Weekly sync**
    ```tasks
    not done
    tag includes #sync
    ```
    **15:30 - Roadmap review**
    ```tasks
    not done
    tag includes #roadmap
    ```
    ## Overdue
    ```tasks
    not done
    due before today
    ```
    ## Tasks
    - [ ] Send the Q4 report draft to the team [[Planning notes]] #sync 🔺 📅 \(d(0))
    - [ ] Reply about the launch date in the [thread](https://example.com/thread) #sync 📅 \(d(-2))
    - [ ] Book a room for the workshop [[Roadmap]] #roadmap ⏫ 🔁 every week 📅 \(d(1))
    - [ ] Collect feedback on the new onboarding #roadmap
    - [ ] Renew the domain 🔼 📅 \(d(0))
    """
    let file = NSTemporaryDirectory() + "taskradarbar-demo.md"
    try! note.write(toFile: file, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: file) }

    let suite = "com.ktar.taskradarbar.demo"
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set(lang, forKey: "lang")
    defaults.set(file, forKey: "notePath")
    defaults.set("Today - meetings", forKey: "section")
    if expanded != nil { defaults.set(["Book a room for the workshop [[Roadmap]]": "Ask facilities for the big room"], forKey: "comments") }

    // "dark" as an extra argument renders the dark appearance (the drawn menu bar stays light: layout check only)
    let dark = CommandLine.arguments.contains("dark")
    NSApplication.shared.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
    let store = Store(defaults: defaults)
    store.demoExpanded = expanded
    let host = NSHostingView(rootView: ContentView().environmentObject(store)
        // a real popover is a light translucent material, noticeably lighter than a window background
        .background(Color(white: dark ? 0.17 : 0.965)))
    // "notify" as an extra argument opens the meeting reminders row
    if CommandLine.arguments.contains("notify") { store.meetingLead = ["Today - meetings": 60]; store.notifying = true }
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 900), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    // let SwiftUI measure the list and settle on its height
    for _ in 0..<8 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
    let size = host.fittingSize
    window.setContentSize(size)
    host.frame = NSRect(origin: .zero, size: size)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))
    guard let content = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap") }
    host.cacheDisplay(in: host.bounds, to: content)

    let shot = frameShot(content, size: size, count: store.visible.count)
    try! shot.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path)")
}

/// Wallpaper, menu bar with the app's status item, and the content as a popover with arrow and shadow.
private func frameShot(_ content: NSBitmapImageRep, size: NSSize, count: Int) -> NSBitmapImageRep {
    let pad: CGFloat = 70, bar: CGFloat = 28, gap: CGFloat = 4, arrow: CGFloat = 11, bottom: CGFloat = 80
    let W = size.width + 2 * pad, H = bar + gap + arrow + size.height + bottom
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(W * 2), pixelsHigh: Int(H * 2), bitsPerSample: 8, samplesPerPixel: 4,
                               hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: W, height: H)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    defer { NSGraphicsContext.restoreGraphicsState() }
    /// AppKit's origin is bottom-left; layout below is written from the top.
    func y(_ top: CGFloat, _ h: CGFloat) -> CGFloat { H - top - h }
    let cx = W / 2

    // wallpaper
    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.56, blue: 0.93, alpha: 1), NSColor(srgbRed: 0.55, green: 0.42, blue: 0.90, alpha: 1),
                        NSColor(srgbRed: 0.93, green: 0.55, blue: 0.62, alpha: 1)])?.draw(in: NSRect(x: 0, y: 0, width: W, height: H), angle: -50)

    // menu bar
    NSColor(white: 1, alpha: 0.66).setFill()
    NSRect(x: 0, y: y(0, bar), width: W, height: bar).fill(using: .sourceOver)
    let ink = NSColor(white: 0, alpha: 0.85)
    func text(_ s: String, at x: CGFloat, weight: NSFont.Weight = .regular, rightAligned: Bool = false) -> CGFloat {
        let a = NSAttributedString(string: s, attributes: [.font: NSFont.systemFont(ofSize: 13, weight: weight), .foregroundColor: ink])
        let w = a.size().width
        a.draw(at: NSPoint(x: rightAligned ? x - w : x, y: y(0, bar) + (bar - a.size().height) / 2))
        return w
    }
    func symbol(_ name: String, at x: CGFloat, rightAligned: Bool = false) -> CGFloat {
        guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 14, weight: .regular)) else { return 0 }
        let w = img.size.width
        img.draw(in: NSRect(x: rightAligned ? x - w : x, y: y(0, bar) + (bar - img.size.height) / 2, width: w, height: img.size.height),
                 from: .zero, operation: .sourceOver, fraction: 0.85)
        return w
    }
    var x: CGFloat = 16
    x += symbol("apple.logo", at: x) + 18
    x += text("Finder", at: x, weight: .semibold) + 18
    for item in ["File", "Edit", "View"] { x += text(item, at: x) + 18 }
    x = W - 16
    x -= text("Mon 23 Nov  9:41", at: x, rightAligned: true) + 16
    for name in ["switch.2", "magnifyingglass", "wifi", "battery.75percent"] { x -= symbol(name, at: x, rightAligned: true) + 16 }

    // the app's status item, pressed: logo + count
    let logo = drawLogo(16, .mono)
    let label = NSAttributedString(string: "\(count)", attributes: [.font: NSFont.systemFont(ofSize: 13), .foregroundColor: ink])
    let itemW = 16 + 5 + label.size().width
    NSColor(white: 0, alpha: 0.13).setFill()
    NSBezierPath(roundedRect: NSRect(x: cx - itemW / 2 - 8, y: y(3, bar - 6), width: itemW + 16, height: bar - 6), xRadius: 5, yRadius: 5).fill()
    logo.draw(in: NSRect(x: cx - itemW / 2, y: y(0, bar) + (bar - 16) / 2, width: 16, height: 16), from: .zero, operation: .sourceOver, fraction: 0.9)
    label.draw(at: NSPoint(x: cx - itemW / 2 + 21, y: y(0, bar) + (bar - label.size().height) / 2))

    // popover: rounded body + arrow, system-like shadow, then the real window content clipped into it
    let top = bar + gap + arrow
    let body = NSRect(x: pad, y: y(top, size.height), width: size.width, height: size.height)
    let shape = NSBezierPath(roundedRect: body, xRadius: 11, yRadius: 11)
    shape.move(to: NSPoint(x: cx - 13, y: body.maxY))
    shape.line(to: NSPoint(x: cx, y: body.maxY + arrow))
    shape.line(to: NSPoint(x: cx + 13, y: body.maxY))
    shape.close()
    let bg = content.colorAt(x: 4, y: 4) ?? NSColor(white: 0.93, alpha: 1)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowBlurRadius = 30
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.shadowColor = NSColor(white: 0, alpha: 0.38)
    shadow.set()
    bg.setFill()
    shape.fill()
    NSGraphicsContext.restoreGraphicsState()
    NSGraphicsContext.saveGraphicsState()
    NSBezierPath(roundedRect: body, xRadius: 11, yRadius: 11).addClip()
    content.draw(in: body)
    NSGraphicsContext.restoreGraphicsState()
    NSColor(white: 0, alpha: 0.18).setStroke()
    shape.lineWidth = 0.5
    shape.stroke()
    return rep
}
