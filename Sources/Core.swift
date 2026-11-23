import Foundation

// MARK: - Dates (as "yyyy-MM-dd" strings: they compare correctly lexicographically)

let dayFmt: DateFormatter = {
    let f = DateFormatter()
    f.calendar = Calendar(identifier: .gregorian)
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

func day(_ d: Date = Date()) -> String { dayFmt.string(from: d) }
func addDays(_ n: Int, to d: Date = Date()) -> Date { Calendar.current.date(byAdding: .day, value: n, to: d)! }

// MARK: - Regex helpers

func groups(_ pattern: String, _ s: String) -> [String]? {
    guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]),
          let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) else { return nil }
    return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
}

func allMatches(_ pattern: String, _ s: String) -> [String] {
    guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
    return re.matches(in: s, range: NSRange(s.startIndex..., in: s)).compactMap { Range($0.range, in: s).map { String(s[$0]) } }
}

func sub(_ s: String, _ pattern: String, _ with: String = "") -> String {
    s.replacingOccurrences(of: pattern, with: NSRegularExpression.escapedTemplate(for: with), options: .regularExpression)
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespaces) }
}

let dateRe = "\\d{4}-\\d{2}-\\d{2}"
let prioRe = "[🔺⏫🔼🔽⏬]\\uFE0F?"
let metaDateRe = "[📅⏳🛫➕✅❌]\\uFE0F? *" + dateRe
let recurRe = "🔁\\uFE0F? *[A-Za-z0-9, ]*[A-Za-z0-9]" // "🔁 every 2 weeks when done"
let tagRe = "(?<!\\S)#[^\\s#]+"
let radarTagRe = "(?<!\\S)#mod/radar(/ask|/wait)?(?![\\w/-])"

// MARK: - Task line

struct TaskItem: Identifiable, Equatable {
    let line: Int        // index in file at read time; only a hint, writes match by exact text
    let raw: String
    let prefix: String   // indent + "- ["
    let status: Character
    let body: String

    // Derived once at parse time: the list re-renders often and each of these is a regex.
    let due: String?
    let scheduled: String?
    let priority: String?
    let tags: [String]
    let recurrence: String?   // rule text after 🔁, e.g. "every week"
    let hasRadarTag: Bool
    /// Body without tags, dates and priority.
    let title: String

    var id: String { "\(line)|\(raw)" }
    // ponytail: status types hardcoded (x = done, - = cancelled), not read from the Tasks plugin's data.json
    var isOpen: Bool { !"xX-".contains(status) }

    static func parse(_ raw: String, line: Int) -> TaskItem? {
        guard let g = groups("^(\\s*(?:>\\s*)*[-*+] \\[)(.)\\] (.*)$", raw), let st = g[2].first else { return nil }
        let body = g[3]
        return TaskItem(
            line: line, raw: raw, prefix: g[1], status: st, body: body,
            due: groups("📅\\uFE0F? *(\(dateRe))", body)?[1],
            scheduled: groups("⏳\\uFE0F? *(\(dateRe))", body)?[1],
            priority: groups("([🔺⏫🔼🔽⏬])", body)?[1],
            tags: allMatches(tagRe, body),
            recurrence: groups("🔁\\uFE0F? *([A-Za-z0-9, ]*[A-Za-z0-9])", body)?[1],
            hasRadarTag: groups(radarTagRe, body) != nil,
            title: sub(sub(sub(sub(body, "\\s*" + recurRe), "\\s*" + metaDateRe), "\\s*" + prioRe), "\\s*" + tagRe).trimmed)
    }
}

// MARK: - Edits (pure: task -> new line text)

enum Edit {
    case done, cancel
    case due(String?)
    case priority(String?)
    case subtag(String)   // "", "/ask", "/wait"
    case text(String)     // whole body after the checkbox
    case recurrence(String?) // rule in Tasks syntax ("every week"), nil removes it
}

/// Append at end of line, but keep a trailing block id (^abc) last.
func appendToken(_ body: String, _ tok: String) -> String {
    if let r = body.range(of: "\\s+\\^[A-Za-z0-9-]+\\s*$", options: .regularExpression) {
        return body[..<r.lowerBound] + " " + tok + body[r]
    }
    return (body.trimmed.isEmpty ? "" : sub(body, "\\s+$") + " ") + tok
}

/// Insert before the first date token so priority/tags stay where the Tasks plugin writes them.
func insertMeta(_ body: String, _ tok: String) -> String {
    if let r = body.range(of: "\\s*" + metaDateRe, options: .regularExpression) {
        return body[..<r.lowerBound] + " " + tok + body[r.lowerBound...]
    }
    return appendToken(body, tok)
}

/// Trailing run of tags / priority / dates / block id. A comment must go before it:
/// the Tasks plugin only reads metadata from the end of the line.
let trailingMetaRe = "(?:\\s+(?:#[^\\s#]+|" + prioRe + "|" + metaDateRe + "|[🆔⛔]\\uFE0F? *[\\w,-]+|" + recurRe + "|\\^[A-Za-z0-9-]+))*\\s*$"

/// User-typed text goes into a single markdown line: no \n, \r, U+2028 and friends.
func oneLine(_ s: String) -> String {
    s.components(separatedBy: .newlines).joined(separator: " ").trimmed
}

func insertComment(_ body: String, _ comment: String) -> String {
    let text = oneLine(comment)
    guard !text.isEmpty else { return body }
    let r = body.range(of: trailingMetaRe, options: .regularExpression) ?? body.endIndex..<body.endIndex
    return body[..<r.lowerBound] + " 💬 " + text + body[r]
}

/// `comment` is written into the line only together with a status change (done / cancel).
func edit(_ e: Edit, _ t: TaskItem, today: String = day(), comment: String? = nil) -> String {
    var status = t.status
    var body = t.body
    switch e {
    case .done, .cancel:
        let isDone: Bool = { if case .done = e { return true } else { return false } }()
        status = isDone ? "x" : "-"
        body = appendToken(sub(body, "\\s*[✅❌]\\uFE0F? *" + dateRe), (isDone ? "✅ " : "❌ ") + today)
        if let comment { body = insertComment(body, comment) }
    case .due(let d):
        let re = "📅\\uFE0F? *" + dateRe
        if let d {
            body = t.due != nil ? sub(body, re, "📅 " + d) : appendToken(body, "📅 " + d)
        } else {
            body = sub(body, "\\s*" + re)
        }
    case .priority(let p):
        body = sub(body, "\\s*" + prioRe)
        if let p { body = insertMeta(body, p) }
    case .subtag(let kind):
        // ponytail: subtags are the task-radar convention (#mod/radar, /ask, /wait), not configurable
        let tag = "#mod/radar" + kind
        if let r = body.range(of: radarTagRe, options: .regularExpression) {
            let rest = sub(String(body[r.upperBound...]), "\\s*" + radarTagRe)
            body = body[..<r.lowerBound] + tag + rest
        } else {
            body = insertMeta(body, tag)
        }
    case .text(let s):
        body = oneLine(s)
    case .recurrence(let rule):
        body = sub(body, "\\s*" + recurRe)
        if let rule {
            body = insertMeta(body, "🔁 " + rule)
            // the Tasks plugin needs a date to repeat from
            if groups("[📅⏳🛫]\\uFE0F? *" + dateRe, body) == nil { body = appendToken(body, "📅 " + today) }
        }
    }
    return t.prefix + String(status) + "] " + body
}

// MARK: - Recurrence

/// The next occurrence of a recurring task as a new open line, the way the Tasks plugin makes it when a task is
/// closed: every planning date moves by the same number of days. nil = a rule this app doesn't understand.
// ponytail: only "every [N] day|week|month|year", "every weekday", optional "when done"; the rest is closed in Obsidian
func nextOccurrence(_ t: TaskItem, today: String = day()) -> String? {
    guard var rule = t.recurrence?.lowercased() else { return nil }
    let whenDone = rule.hasSuffix(" when done")
    if whenDone { rule = String(rule.dropLast(" when done".count)) }
    var step: (Calendar.Component, Int)?
    if rule != "every weekday" {
        guard let g = groups("^every (?:(\\d+) )?(day|week|month|year)s?$", rule), let n = g[1].isEmpty ? 1 : Int(g[1]), n > 0 else { return nil }
        step = ["day": (.day, n), "week": (.day, 7 * n), "month": (.month, n), "year": (.year, n)][g[2]]
    }
    let planning = ["📅", "⏳", "🛫"].map { ($0, groups($0 + "\\uFE0F? *(" + dateRe + ")", t.body)?[1]) }
    guard let ref = planning.compactMap(\.1).first, let refDate = dayFmt.date(from: ref),
          let base = whenDone ? dayFmt.date(from: today) : refDate else { return t.raw } // no dates: a plain copy
    var next: Date
    if let step {
        guard let d = Calendar.current.date(byAdding: step.0, value: step.1, to: base) else { return nil }
        next = d
    } else {
        next = addDays(1, to: base)
        while Calendar.current.isDateInWeekend(next) { next = addDays(1, to: next) }
    }
    let delta = Calendar.current.dateComponents([.day], from: refDate, to: next).day ?? 0
    var line = t.raw
    for (emoji, d) in planning {
        if let d, let date = dayFmt.date(from: d) {
            line = sub(line, emoji + "\\uFE0F? *" + dateRe, emoji + " " + day(addDays(delta, to: date)))
        }
    }
    return line
}

// MARK: - File patching

struct Fail: Error { let msg: String }

func splitLines(_ text: String) -> ([String], String) {
    let nl = text.contains("\r\n") ? "\r\n" : "\n"
    return (text.components(separatedBy: nl), nl)
}

/// Re-reads the file, finds the task by exact line text (nearest to its old position),
/// replaces only that line, writes atomically and verifies.
func patchFile(_ notePath: String, _ t: TaskItem, _ e: Edit, comment: String? = nil) throws {
    var next: String? // closing a recurring task also adds its next occurrence, like the Tasks plugin does
    switch e {
    case .done:
        if let rule = t.recurrence {
            guard let n = nextOccurrence(t) else {
                throw Fail(msg: "Правило повторения «\(rule)» приложение не понимает. Закрой эту задачу в Obsidian, иначе следующее повторение не создастся.")
            }
            next = n
        } else if t.body.contains("🔁") {
            throw Fail(msg: "Не разобрал правило повторения. Закрой эту задачу в Obsidian.")
        }
    case .text(let s):
        if oneLine(s).isEmpty { throw Fail(msg: "Пустой текст задачи не сохраняю.") }
    default: break
    }
    // An atomic write replaces the file at the path; if the note is a symlink, write to its target, not over the link.
    let path = URL(fileURLWithPath: notePath).resolvingSymlinksInPath().path
    let text = try String(contentsOfFile: path, encoding: .utf8)
    var (lines, nl) = splitLines(text)
    guard let i = lines.indices.filter({ lines[$0] == t.raw }).min(by: { abs($0 - t.line) < abs($1 - t.line) }) else {
        throw Fail(msg: "Строка задачи изменилась в заметке. Список обновлён, повтори действие.")
    }
    lines[i] = edit(e, t, comment: comment)
    if let next { lines.insert(next, at: i) } // above the closed one, as Tasks does by default
    let out = lines.joined(separator: nl)
    try out.write(toFile: path, atomically: true, encoding: .utf8)
    guard try String(contentsOfFile: path, encoding: .utf8) == out else {
        throw Fail(msg: "Запись не подтвердилась, проверь заметку.")
    }
}

// MARK: - Sections = ```tasks blocks of the note

typealias Pred = (TaskItem) -> Bool

struct Section: Identifiable {
    var name: String
    var preds: [Pred]
    var limit: Int?
    var error: String?
    var heading = ""          // markdown heading the block sits under
    var sub: String?          // bold label right above the block, e.g. a meeting
    var children: [Section] = []  // filled only for merged sections
    var id: String { name }

    func select(_ tasks: [TaskItem], sort: Sort = .due) -> [TaskItem] {
        var f = tasks.filter { t in preds.allSatisfy { $0(t) } }
        switch sort {
        case .due: f.sort { a, b in (a.due ?? "9999", a.line) < (b.due ?? "9999", b.line) }
        case .priority: f.sort { a, b in (prioRank(a.priority), a.due ?? "9999", a.line) < (prioRank(b.priority), b.due ?? "9999", b.line) }
        case .file: break
        }
        return limit.map { Array(f.prefix($0)) } ?? f
    }
}

enum Sort: String, CaseIterable {
    case due, priority, file
    var title: String {
        switch self {
        case .due: return "По сроку: старые сверху"   // no due date goes last, in file order
        case .priority: return "По приоритету, затем по сроку"
        case .file: return "Как в заметке"
        }
    }
}

func prioRank(_ p: String?) -> Int { ["🔺": 0, "⏫": 1, "🔼": 2, "🔽": 4, "⏬": 5][p ?? ""] ?? 3 }

func dateRange(_ w: String, _ now: Date) -> (String, String)? {
    switch w {
    case "today": return (day(now), day(now))
    case "tomorrow": return (day(addDays(1, to: now)), day(addDays(1, to: now)))
    case "yesterday": return (day(addDays(-1, to: now)), day(addDays(-1, to: now)))
    case "this week", "next week", "last week":
        var cal = Calendar(identifier: .iso8601) // Tasks plugin weeks are Mon-Sun
        cal.timeZone = .current
        let off = w.hasPrefix("this") ? 0 : w.hasPrefix("next") ? 7 : -7
        guard let iv = cal.dateInterval(of: .weekOfYear, for: addDays(off, to: now)) else { return nil }
        return (day(iv.start), day(addDays(6, to: iv.start)))
    default:
        return groups("^\(dateRe)$", w) != nil ? (w, w) : nil
    }
}

// ponytail: only the Tasks query filters listed here; anything else makes the section show an error
func atom(_ s: String, _ now: Date) -> Pred? {
    let l = s.lowercased().trimmed
    if l == "not done" { return { $0.isOpen } }
    if l == "done" { return { !$0.isOpen } }
    if let g = groups("^(no|has) (due|scheduled) date$", l) {
        let has = g[1] == "has", due = g[2] == "due"
        return { t in ((due ? t.due : t.scheduled) != nil) == has }
    }
    if let g = groups("^(due|scheduled) (?:(on or before|on or after|before|after|on|in) )?(.+)$", l), let r = dateRange(g[3], now) {
        let due = g[1] == "due", op = g[2]
        return { t in
            guard let d = due ? t.due : t.scheduled else { return false }
            switch op {
            case "before": return d < r.0
            case "after": return d > r.1
            case "on or before": return d <= r.1
            case "on or after": return d >= r.0
            default: return d >= r.0 && d <= r.1
            }
        }
    }
    if let g = groups("^tags? (includes?|does not include|do not include) (.+)$", l) {
        let neg = g[1].contains("not"), v = g[2]
        return { t in t.tags.contains { $0.lowercased().contains(v) } != neg }
    }
    if let g = groups("^description (includes|does not include) (.+)$", l) {
        let neg = g[1].contains("not"), v = g[2]
        return { t in t.title.lowercased().contains(v) != neg }
    }
    return nil
}

/// `(a) OR (b)`, `(a) AND NOT (b)`, `NOT (a)`, nested; a line without parens is a single filter.
func parseExpr(_ str: String, _ now: Date) -> Pred? {
    let s = str.trimmed
    guard s.hasPrefix("(") || groups("^NOT\\s*\\(", s) != nil else { return atom(s, now) } // "not done" is an atom
    var result: Pred?
    var depth = 0, between = "", group = ""
    for ch in s {
        if ch == "(" { depth += 1; if depth == 1 { continue } }
        if ch == ")" {
            depth -= 1
            if depth == 0 {
                guard var p = parseExpr(group, now) else { return nil }
                let op = between.uppercased()
                if op.contains("NOT") { let q = p; p = { !q($0) } }
                if let r = result {
                    let q = p
                    if op.contains("XOR") { return nil }
                    else if op.contains("OR") { result = { r($0) || q($0) } }
                    else if op.contains("AND") { result = { r($0) && q($0) } }
                    else { return nil }
                } else {
                    guard op.trimmed.isEmpty || op.trimmed == "NOT" else { return nil }
                    result = p
                }
                group = ""; between = ""
                continue
            }
        }
        if depth > 0 { group.append(ch) } else { between.append(ch) }
    }
    guard depth == 0, between.trimmed.isEmpty else { return nil }
    return result
}

func makeSection(_ name: String, _ query: [String], _ now: Date) -> Section {
    let ignored = ["short", "full mode", "sort by", "group by", "hide ", "show ", "explain", "#", "limit groups", "ignore global query"]
    var preds: [Pred] = [], limit: Int?, error: String?
    for q in query {
        let l = q.lowercased().trimmed
        if l.isEmpty || ignored.contains(where: l.hasPrefix) { continue }
        if let g = groups("^limit (?:to )?(\\d+)", l) { limit = Int(g[1]); continue }
        if let p = parseExpr(q, now) { preds.append(p) } else if error == nil { error = "Не понял строку запроса: «\(q.trimmed)»" }
    }
    return Section(name: name, preds: preds, limit: limit, error: error)
}

func parseNote(_ text: String, now: Date = Date()) -> ([TaskItem], [Section]) {
    var tasks: [TaskItem] = [], sections: [Section] = []
    var heading = "Задачи", sub2: String?, query: [String]?, inFence = false
    for (i, raw) in splitLines(text).0.enumerated() {
        let line = raw.trimmed
        if query != nil {
            if line.hasPrefix("```") {
                let label = sub2.map { heading + " › " + $0 } ?? heading
                let n = sections.filter { $0.name == label || $0.name.hasPrefix(label + " (") }.count
                var sec = makeSection(n == 0 ? label : "\(label) (\(n + 1))", query!, now)
                sec.heading = heading
                sec.sub = sub2
                sections.append(sec)
                query = nil
            } else {
                query!.append(line)
            }
            continue
        }
        if line.hasPrefix("```") || line.hasPrefix("~~~") {
            if !inFence && line.lowercased().hasPrefix("```tasks") { query = [] } else { inFence.toggle() }
            continue
        }
        if inFence { continue }
        if let g = groups("^#{1,6}\\s+(.+)$", line) { heading = g[1]; sub2 = nil; continue }
        if let g = groups("^\\*\\*(.+)\\*\\*$", line) { sub2 = g[1]; continue } // e.g. per-meeting blocks
        if let t = TaskItem.parse(raw, line: i) { tasks.append(t) }
    }
    sections.append(Section(name: "Все открытые", preds: [{ $0.isOpen }], limit: nil, error: nil))
    return (tasks, sections)
}

/// Blocks that share a heading and differ only by their bold label (per-meeting blocks) become one section:
/// a task is in it if it matches any of the blocks. The blocks stay in `children` for group headers.
func mergeSections(_ sections: [Section]) -> [Section] {
    var out: [Section] = []
    for s in sections {
        if s.sub == nil { out.append(s); continue }
        if let i = out.firstIndex(where: { !$0.children.isEmpty && $0.heading == s.heading }) {
            out[i].children.append(s)
        } else {
            out.append(Section(name: s.heading, preds: [], limit: nil, error: nil, heading: s.heading, sub: nil, children: [s]))
        }
    }
    return out.map { m in
        guard !m.children.isEmpty else { return m }
        let kids = m.children
        var r = m
        r.preds = [{ t in kids.contains { k in k.preds.allSatisfy { $0(t) } } }]
        r.error = kids.compactMap(\.error).first
        return r
    }
}

// MARK: - Self-check: `taskradarbar --selftest [path-to-note]`

func selfTest() {
    func eq(_ a: String, _ b: String) { precondition(a == b, "\n got: \(a)\nwant: \(b)") }
    let now = dayFmt.date(from: "2026-11-23")! // Monday
    let note = """
    ## Сегодня
    ```tasks
    not done
    (due on today) OR (scheduled today)
    tag does not include #mod/radar/wait
    limit 200
    short mode
    sort by priority
    ```
    ## Неделя
    ```tasks
    not done
    (due this week) OR (due next week)
    due after tomorrow
    ```
    ## Сломано
    ```tasks
    path includes foo
    ```
    ## Задачи
    - [ ] a [[note|n]] #mod/radar 🔺 📅 2026-11-23
    - [ ] b #mod/radar/wait 📅 2026-11-23
    - [x] c #mod/radar 📅 2026-11-23 ✅ 2026-11-23
    - [ ] d #mod/radar 📅 2026-11-27
    - [ ] e #mod/radar ⏳ 2026-11-23 📅 2026-11-20
    - [ ] f #mod/radar
    - [ ] g ^abc
    ```
    - [ ] in code
    ```
    """
    let (tasks, sections) = parseNote(note, now: now)
    precondition(tasks.count == 7, "tasks: \(tasks.count)")
    eq(sections.map(\.name).joined(separator: ","), "Сегодня,Неделя,Сломано,Все открытые")
    eq(sections[0].select(tasks).map(\.title).joined(separator: ","), "e,a [[note|n]]")
    eq(sections[1].select(tasks).map(\.title).joined(separator: ","), "d")
    precondition(sections[2].error != nil && sections[0].error == nil)
    precondition(sections[3].select(tasks).count == 6)

    let (a, b, d, f, g) = (tasks[0], tasks[1], tasks[3], tasks[5], tasks[6])
    let td = "2026-11-23"
    eq(edit(.done, a, today: td), "- [x] a [[note|n]] #mod/radar 🔺 📅 2026-11-23 ✅ 2026-11-23")
    eq(edit(.cancel, f, today: td), "- [-] f #mod/radar ❌ 2026-11-23")
    eq(edit(.due("2026-11-24"), a), "- [ ] a [[note|n]] #mod/radar 🔺 📅 2026-11-24")
    eq(edit(.due("2026-11-24"), f), "- [ ] f #mod/radar 📅 2026-11-24")
    eq(edit(.due("2026-11-24"), g), "- [ ] g 📅 2026-11-24 ^abc")
    eq(edit(.due(nil), a), "- [ ] a [[note|n]] #mod/radar 🔺")
    eq(edit(.priority(nil), a), "- [ ] a [[note|n]] #mod/radar 📅 2026-11-23")
    eq(edit(.priority("⏫"), a), "- [ ] a [[note|n]] #mod/radar ⏫ 📅 2026-11-23")
    eq(edit(.priority("⏫"), f), "- [ ] f #mod/radar ⏫")
    eq(edit(.priority("⏫"), d), "- [ ] d #mod/radar ⏫ 📅 2026-11-27")
    eq(edit(.subtag("/wait"), a), "- [ ] a [[note|n]] #mod/radar/wait 🔺 📅 2026-11-23")
    eq(edit(.subtag(""), b), "- [ ] b #mod/radar 📅 2026-11-23")
    eq(edit(.text("new text 📅 2026-12-01"), a), "- [ ] new text 📅 2026-12-01")
    eq(edit(.done, a, today: td, comment: "сделал, см. тред"), "- [x] a [[note|n]] 💬 сделал, см. тред #mod/radar 🔺 📅 2026-11-23 ✅ 2026-11-23")
    eq(edit(.cancel, g, today: td, comment: "неактуально"), "- [-] g 💬 неактуально ❌ 2026-11-23 ^abc")
    eq(edit(.due("2026-11-24"), f, comment: "ignored"), "- [ ] f #mod/radar 📅 2026-11-24")
    precondition(TaskItem.parse(edit(.done, a, today: td, comment: "c"), line: 0)?.due == "2026-11-23")
    let (mt, ms) = parseNote("""
    ## Встречи
    **10:00 - A**
    ```tasks
    tag includes #t1
    ```
    **11:00 - B**
    ```tasks
    tag includes #t2
    ```
    - [ ] one #t1
    - [ ] two #t2
    - [ ] both #t1 #t2
    - [ ] none
    """, now: now)
    let merged = mergeSections(ms)
    eq(ms.map(\.name).joined(separator: ","), "Встречи › 10:00 - A,Встречи › 11:00 - B,Все открытые")
    eq(merged.map(\.name).joined(separator: ","), "Встречи,Все открытые")
    precondition(merged[0].children.count == 2 && merged[0].select(mt).count == 3)
    eq(edit(.text("a\r\nb\u{2028}c"), a), "- [ ] a  b c")
    let rec = NSTemporaryDirectory() + "taskradarbar-selftest-rec.md"
    try! "- [ ] weekly 🔁 every week 📅 2026-11-23\n".write(toFile: rec, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(atPath: rec) }
    let recTask = TaskItem.parse("- [ ] weekly 🔁 every week 📅 2026-11-23", line: 0)!
    do { try patchFile(rec, recTask, .text("  ")); preconditionFailure("empty text must be rejected") } catch {}
    eq(recTask.recurrence ?? "", "every week")
    eq(recTask.title, "weekly")
    try! patchFile(rec, recTask, .done)
    let recOut = try! String(contentsOfFile: rec, encoding: .utf8)
    eq(recOut, "- [ ] weekly 🔁 every week 📅 2026-11-30\n- [x] weekly 🔁 every week 📅 2026-11-23 ✅ \(day())\n")
    func nxt(_ l: String) -> String? { nextOccurrence(TaskItem.parse(l, line: 0)!, today: td) }
    eq(nxt("- [ ] m 🔁 every month ⏳ 2026-01-29 📅 2026-01-31") ?? "nil", "- [ ] m 🔁 every month ⏳ 2026-02-26 📅 2026-02-28")
    eq(nxt("- [ ] w 🔁 every weekday 📅 2026-11-27") ?? "nil", "- [ ] w 🔁 every weekday 📅 2026-11-30")
    eq(nxt("- [ ] d 🔁 every 2 weeks when done 📅 2026-11-01") ?? "nil", "- [ ] d 🔁 every 2 weeks when done 📅 2026-12-07")
    precondition(nxt("- [ ] x 🔁 every month on the 15th 📅 2026-11-15") == nil)
    let odd = TaskItem.parse("- [ ] x 🔁 every month on the 15th 📅 2026-11-15", line: 0)!
    try! "\(odd.raw)\n".write(toFile: rec, atomically: true, encoding: .utf8)
    do { try patchFile(rec, odd, .done); preconditionFailure("unknown rule must be rejected") } catch {}
    eq(edit(.recurrence("every week"), a, today: td), "- [ ] a [[note|n]] #mod/radar 🔺 🔁 every week 📅 2026-11-23")
    eq(edit(.recurrence("every day"), f, today: td), "- [ ] f #mod/radar 🔁 every day 📅 2026-11-23")
    eq(edit(.recurrence(nil), recTask), "- [ ] weekly 📅 2026-11-23")
    eq(edit(.done, recTask, today: td, comment: "c"), "- [x] weekly 💬 c 🔁 every week 📅 2026-11-23 ✅ 2026-11-23")
    print("synthetic checks: ok")

    // Real note: work on a temp copy, the original is never written.
    guard let path = CommandLine.arguments.dropFirst(2).first else { return }
    let tmp = NSTemporaryDirectory() + "taskradarbar-selftest.md"
    try? FileManager.default.removeItem(atPath: tmp)
    try! FileManager.default.copyItem(atPath: path, toPath: tmp)
    defer { try? FileManager.default.removeItem(atPath: tmp) } // don't leave a copy of the note in the temp dir
    let before = try! String(contentsOfFile: tmp, encoding: .utf8)
    let (rt, rs) = parseNote(before)
    for s in rs { print(String(format: "%4d", s.select(rt).count), s.name, s.error.map { "  ⚠️ " + $0 } ?? "") }
    guard let victim = rs.last!.select(rt).first else { return }
    try! patchFile(tmp, victim, .due(day(addDays(1))))
    let after = try! String(contentsOfFile: tmp, encoding: .utf8)
    let (l1, l2) = (splitLines(before).0, splitLines(after).0)
    let diff = zip(l1, l2).filter { $0 != $1 }
    precondition(l1.count == l2.count && diff.count == 1, "patch touched \(diff.count) lines")
    print("patch on copy: exactly 1 line changed\n -", diff[0].0, "\n +", diff[0].1)
    do { try patchFile(tmp, victim, .done); preconditionFailure("stale line must be rejected") } catch { print("stale line rejected: ok") }
}
