import SwiftUI
import UserNotifications

// MARK: - Reminders before meetings
// A meeting is a query block whose bold label starts with a time: **15:30 - Roadmap review**.
// The app itself posts one notification with the block's tasks N minutes before that time, composed at that
// moment so the text is never stale. Nothing is scheduled with macOS: if the app isn't running or the Mac sleeps
// through that moment, the reminder is skipped, not sent late.

/// "15:30 - Review" -> 930 (minutes from midnight); nil when the label doesn't start with a time.
// ponytail: the time is taken as today's, a date in the label is not read
func meetingMinutes(_ label: String) -> Int? {
    guard let g = groups("^(\\d{1,2})[:.](\\d{2})(?!\\d)", label.trimmed), let h = Int(g[1]), let m = Int(g[2]), h < 24, m < 60 else { return nil }
    return h * 60 + m
}

/// True only in the two minutes after "start - lead": wide enough for the 3 s poll, narrow enough that a Mac
/// waking up later skips the reminder.
// ponytail: no reminders across midnight (a 00:30 meeting with a 1 h lead never fires)
func meetingDue(_ label: String, lead: Int, nowMinutes: Int) -> Bool {
    guard let start = meetingMinutes(label) else { return false }
    return (0..<2).contains(nowMinutes - (start - lead))
}

func digestBody(_ titles: [String]) -> String {
    let lines = titles.prefix(5).map { "• " + $0 }
    return (lines + (titles.count > 5 ? [L("and %@ more", "\(titles.count - 5)")] : [])).joined(separator: "\n")
}

private func minutesNow(_ now: Date = Date()) -> Int {
    let c = Calendar.current.dateComponents([.hour, .minute], from: now)
    return (c.hour ?? 0) * 60 + (c.minute ?? 0)
}

extension Store {
    /// The setting is per note heading, so it survives the "merge blocks" toggle and a language switch.
    // ponytail: renaming the heading in the note orphans the setting
    var meetingKey: String { section?.heading ?? "" }

    /// Blocks with a time in their label under the current section's heading.
    var meetings: [Section] {
        let h = meetingKey
        return h.isEmpty ? [] : rawSections.filter { $0.heading == h && $0.sub.flatMap(meetingMinutes) != nil }
    }

    /// Minutes before a meeting under this heading; 0 = no reminders. The section's own choice wins over the
    /// default from the gear menu.
    func lead(_ heading: String) -> Int { meetingLead[heading] ?? meetingDefault }

    /// nil = follow the default, 0 = off for this section.
    func setMeetingLead(_ minutes: Int?) {
        meetingLead[meetingKey] = minutes
        if lead(meetingKey) > 0 { askNotifications() }
    }

    /// Ask when reminders are switched on, not when the first one is due and nobody is looking.
    func askNotifications() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if !granted { DispatchQueue.main.async { self.error = L("Notifications are off: System Settings → Notifications → TaskRadarBar") } }
        }
    }

    /// Called on every poll tick.
    func checkMeetings(now: Date = Date()) {
        guard hasBundle else { return }
        let today = day(now), mins = minutesNow(now)
        // sent today, kept in defaults so a restart inside the window doesn't send twice
        let saved = defaults.stringArray(forKey: "meetingFired") ?? []
        var fired = saved.filter { $0.hasPrefix(today) }
        for b in rawSections {
            let lead = lead(b.heading)
            guard lead > 0, let label = b.sub, b.error == nil, meetingDue(label, lead: lead, nowMinutes: mins) else { continue }
            let key = "\(today)|\(lead)|\(b.name)" // lead in the key: picking another lead later that day reminds again
            guard !fired.contains(key) else { continue }
            fired.append(key)
            postDigest(b, after: 1)
        }
        if fired != saved { defaults.set(fired, forKey: "meetingFired") }
    }

    /// One notification with the block's tasks; an empty block sends nothing.
    @discardableResult
    func postDigest(_ b: Section, after: TimeInterval) -> Bool {
        let items = b.select(tasks, sort: sort)
        guard let label = b.sub, !items.isEmpty else { return false }
        post(id: "meeting|" + b.name, title: "\(label) · \(items.count)", body: digestBody(items.map { String(rich($0).characters) }), after: after)
        return true
    }

    /// "Check": the nearest meeting that has tasks, in 5 seconds, through the same code as the real reminder.
    func testMeetingDigest() {
        let now = minutesNow()
        let byTime = meetings.sorted { (meetingMinutes($0.sub ?? "") ?? 0) < (meetingMinutes($1.sub ?? "") ?? 0) }
        let nearestFirst = byTime.filter { (meetingMinutes($0.sub ?? "") ?? 0) >= now } + byTime.filter { (meetingMinutes($0.sub ?? "") ?? 0) < now }
        if nearestFirst.first(where: { postDigest($0, after: 5) }) == nil { error = L("No meetings with tasks in this section") }
    }
}

/// The choices, shared by the gear menu (default) and the section row.
var meetingLeads: [(String, Int)] { [(L("off"), 0), (L("15 min"), 15), (L("30 min"), 30), (L("1 h"), 60), (L("2 h"), 120)] }

/// Settings row under the header, like the search row.
struct MeetingRow: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let own = store.meetingLead[store.meetingKey]
        HStack(spacing: 4) {
            // an icon, not a caption: six chips and "Check" leave no room for text in 480pt
            Image(systemName: "clock").foregroundStyle(.secondary).padding(.trailing, 4).help(L("Before the meeting"))
            chip(L("default"), active: own == nil) { store.setMeetingLead(nil) }
                .help(L("Reminders before meetings") + ": " + (meetingLeads.first { $0.1 == store.meetingDefault }?.0 ?? ""))
            ForEach(meetingLeads, id: \.1) { label, m in
                chip(label, active: own == m) { store.setMeetingLead(m) }
            }
            Spacer(minLength: 0)
            chip(L("Check"), active: false) { store.testMeetingDigest() }
                .help(L("Sends the tasks of the nearest meeting in 5 seconds"))
        }
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }
}

func meetingSelfTest() {
    precondition(meetingMinutes("15:30 - Review") == 930 && meetingMinutes("9.05 Standup") == 545)
    precondition(meetingMinutes("Weekly sync") == nil && meetingMinutes("25:00 - x") == nil && meetingMinutes("2026 plan") == nil)
    let due = { (now: Int) in meetingDue("15:30 - Review", lead: 60, nowMinutes: now) }
    precondition(!due(869) && due(870) && due(871) && !due(872) && !due(930), "meeting reminder window")
    precondition(!meetingDue("00:30 - Night", lead: 60, nowMinutes: 0) && !meetingDue("Weekly", lead: 60, nowMinutes: 0))
    precondition(digestBody(["a", "b"]) == "• a\n• b")
    precondition(digestBody((1...7).map(String.init)) == "• 1\n• 2\n• 3\n• 4\n• 5\nand 2 more")
    print("meeting reminders: ok")
}
