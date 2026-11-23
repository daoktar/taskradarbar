import SwiftUI
import AppKit

/// `taskradarbar --screenshot out.png`: renders the window with made-up tasks, for the README.
/// Nothing is captured from the screen, no real note is read, and the user's settings are not touched.
func writeDemoScreenshot(_ path: String) {
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
    defer { defaults.removePersistentDomain(forName: suite) }
    defaults.set("en", forKey: "lang")
    defaults.set(file, forKey: "notePath")
    defaults.set("Today - meetings", forKey: "section")

    NSApplication.shared.appearance = NSAppearance(named: .aqua)
    let store = Store(defaults: defaults)
    let host = NSHostingView(rootView: ContentView().environmentObject(store).background(Color(nsColor: .windowBackgroundColor)))
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 700), styleMask: [.borderless], backing: .buffered, defer: false)
    window.contentView = host
    // let SwiftUI measure the list and settle on its height
    for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.2)); host.layoutSubtreeIfNeeded() }
    let size = host.fittingSize
    window.setContentSize(size)
    host.frame = NSRect(origin: .zero, size: size)
    RunLoop.main.run(until: Date().addingTimeInterval(0.3))

    guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { fatalError("no bitmap") }
    host.cacheDisplay(in: host.bounds, to: rep)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
    print("wrote \(path) \(Int(size.width))x\(Int(size.height))")
}
