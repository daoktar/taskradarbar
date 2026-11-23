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

/// Characters of one task line in the body: a longer line wraps and pushes the next tasks out of the collapsed banner.
// ponytail: tuned by eye for the default banner width (about 38 characters with the bullet), macOS gives no way
// to measure it; wide letters or a larger system text size can still wrap a line
let digestLine = 34

/// A collapsed banner shows the subtitle and three body lines, so: first task -> subtitle (macOS cuts it to
/// one line itself), tasks 2...8 -> one short body line each, then "and N more".
func digestText(_ titles: [String]) -> (subtitle: String, body: String) {
    let rest = titles.dropFirst().prefix(7).map { "• " + ($0.count > digestLine ? String($0.prefix(digestLine - 1)).trimmed + "…" : $0) }
    return (titles.first ?? "", (rest + (titles.count > 8 ? [L("and %@ more", "\(titles.count - 8)")] : [])).joined(separator: "\n"))
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
        // daily reminders of sections without meetings: same two-minute window, same "sent today" list
        for (name, at) in dailyTime where (0..<2).contains(mins - at) {
            let key = "\(today)|daily|\(at)|\(name)"
            guard !fired.contains(key), let sec = sections.first(where: { $0.name == name }), sec.error == nil else { continue }
            fired.append(key)
            postDaily(sec, after: 1)
        }
        if fired != saved { defaults.set(fired, forKey: "meetingFired") }
    }

    // MARK: Daily reminder for a section
    // ponytail: keyed by the section name as shown, so renaming the heading or switching the language
    // ("All open") orphans the setting; like meeting reminders, skipped if the app isn't running at that minute

    var dailyKey: String { section?.name ?? "" }

    /// nil = off.
    func setDaily(_ minutes: Int?) {
        guard !dailyKey.isEmpty else { return }
        dailyTime[dailyKey] = minutes
        if minutes != nil { askNotifications() }
    }

    /// One notification with all open tasks of the section; an empty section sends nothing.
    @discardableResult
    func postDaily(_ sec: Section, after: TimeInterval) -> Bool {
        let items = sec.select(tasks, sort: .priority)
        guard !items.isEmpty else { return false }
        postDigest(id: "daily|" + sec.name, label: sec.name, items, section: sec.name, after: after)
        return true
    }

    func testDaily() {
        guard let sec = section, postDaily(sec, after: 5) else { error = L("Nothing in this section"); return }
    }

    /// One notification with the block's tasks; an empty block sends nothing.
    @discardableResult
    func postDigest(_ b: Section, after: TimeInterval) -> Bool {
        let items = b.select(tasks, sort: .priority)
        guard let label = b.sub, !items.isEmpty else { return false }
        // with "merge blocks" on, the block is shown inside the section named after its heading
        postDigest(id: "meeting|" + b.name, label: label, items, section: sections.contains { $0.name == b.name } ? b.name : b.heading, after: after)
        return true
    }

    /// The count leads the title so a long label can't cut it off; most urgent tasks first whatever the window's sort.
    private func postDigest(id: String, label: String, _ items: [TaskItem], section: String, after: TimeInterval) {
        let text = digestText(items.map { String(rich($0).characters) })
        post(id: id, title: "\(items.count) · \(label)", subtitle: text.subtitle, body: text.body, section: section, after: after)
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

/// Settings row for a section without timed meetings: one reminder a day with everything in it.
struct DailyRow: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let at = store.dailyTime[store.dailyKey]
        HStack(spacing: 6) {
            Image(systemName: "clock").foregroundStyle(.secondary)
            chip(L("off"), active: at == nil) { store.setDaily(nil) }
            Text(L("Every day at")).font(.callout).foregroundStyle(at == nil ? .secondary : .primary)
            // editing the time switches the reminder on; 9:00 is only what the field shows while it is off
            DatePicker("", selection: Binding(
                get: { Calendar.current.date(bySettingHour: (at ?? 540) / 60, minute: (at ?? 540) % 60, second: 0, of: Date()) ?? Date() },
                set: { d in
                    let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                    store.setDaily((c.hour ?? 9) * 60 + (c.minute ?? 0))
                }), displayedComponents: .hourAndMinute)
                .datePickerStyle(.stepperField)
                .labelsHidden()
                .fixedSize()
            if at == nil { chip(L("on"), active: false) { store.setDaily(540) } }
            Spacer(minLength: 0)
            chip(L("Check"), active: false) { store.testDaily() }
                .help(L("Sends this section's tasks in 5 seconds"))
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
    let three = digestText(["Update slides", "Invite the designer", "Check the numbers"])
    precondition(three.subtitle == "Update slides" && three.body == "• Invite the designer\n• Check the numbers", "digest: three short")
    let long = String(repeating: "Agree the wording with legal ", count: 4)
    let cut = digestText(["Update slides", long, "Check the numbers"]).body.components(separatedBy: "\n")
    precondition(cut.count == 2 && cut[0].count == digestLine + 2 && cut[0].hasSuffix("…") && cut[1] == "• Check the numbers", "digest: long task")
    precondition(digestText([long, "b"]).subtitle == long, "digest: the subtitle is cut by macOS, not here")
    let twelve = digestText((1...12).map { "Task \($0)" })
    precondition(twelve.subtitle == "Task 1" && twelve.body == (2...8).map { "• Task \($0)" }.joined(separator: "\n") + "\nand 4 more", "digest: twelve")
    precondition(digestText(["only"]).body == "" && digestText((1...8).map(String.init)).body.hasSuffix("• 8"), "digest: edges")
    print("meeting reminders: ok")
}
