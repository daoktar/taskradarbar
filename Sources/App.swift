import SwiftUI
import Combine
import AppKit
import UserNotifications
import ServiceManagement
import UniformTypeIdentifiers

@main
enum Main {
    static func main() {
        if CommandLine.arguments.contains("--selftest") { selfTest(); return }
        if let i = CommandLine.arguments.firstIndex(of: "--icon"), CommandLine.arguments.count > i + 1 {
            writeIconPNG(CommandLine.arguments[i + 1]); return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--screenshots"), CommandLine.arguments.count > i + 1 {
            let dir = CommandLine.arguments[i + 1]
            writeDemoScreenshot(dir + "/screenshot.png", expanded: nil)
            writeDemoScreenshot(dir + "/screenshot-panel.png", expanded: "Book a room")
            return
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Status item + NSPopover. SwiftUI's MenuBarExtra(.window) can't follow a changing content height:
/// it resizes from the bottom-left corner and leaves transparent gaps. A popover resizes anchored to the icon.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate, NSPopoverDelegate {
    let store = Store()
    let popover = NSPopover()
    var item: NSStatusItem!
    var sub: AnyCancellable?
    var shownIcon = ""
    var closedAt = Date.distantPast

    func applicationDidFinishLaunching(_ notification: Notification) {
        if hasBundle { UNUserNotificationCenter.current().delegate = self }

        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.button?.imagePosition = .imageLeading
        item.button?.target = self
        item.button?.action = #selector(toggle)

        let host = NSHostingController(rootView: ContentView().environmentObject(store))
        host.sizingOptions = [.preferredContentSize] // popover follows the SwiftUI content size
        popover.contentViewController = host
        popover.behavior = .transient
        popover.delegate = self
        popover.animates = false

        updateTitle()
        sub = store.objectWillChange.sink { [weak self] in DispatchQueue.main.async { self?.updateTitle() } }
    }

    func updateTitle() {
        item.button?.title = " \(store.visible.count)"
        guard shownIcon != store.trayIcon else { return }
        shownIcon = store.trayIcon
        switch store.trayIcon {
        case "mono":
            let img = drawLogo(18, .mono)
            img.isTemplate = true // follows the menu bar's light/dark colour
            item.button?.image = img
        case "color":
            item.button?.image = drawLogo(18, .color)
        default:
            item.button?.image = NSImage(systemSymbolName: "scope", accessibilityDescription: "TaskRadarBar")
        }
    }

    @objc func toggle() {
        guard let button = item.button else { return }
        if popover.isShown { popover.performClose(nil); return }
        // A click on the icon is also a click outside the popover: the transient popover closes itself on
        // mouse-down, and this action would then reopen it. Treat a click right after that close as "close".
        if Date().timeIntervalSince(closedAt) < 0.3 { return }
        store.reload()
        store.refreshReminders()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

    func popoverDidClose(_ notification: Notification) { closedAt = Date() }

    // Show the banner even though the app counts as "foreground".
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler handler: @escaping (UNNotificationPresentationOptions) -> Void) {
        handler([.banner, .sound])
    }
}

/// UNUserNotificationCenter crashes when run as a bare binary without a bundle.
var hasBundle: Bool { Bundle.main.bundleIdentifier != nil }

// MARK: - Store

final class Store: ObservableObject {
    @Published var tasks: [TaskItem] = []
    @Published var rawSections: [Section] = []
    @Published var mergeBlocks: Bool {
        didSet { defaults.set(mergeBlocks, forKey: "mergeBlocks") }
    }
    var sections: [Section] { mergeBlocks ? mergeSections(rawSections) : rawSections }
    @Published var error: String?
    @Published var reminders: Set<String> = []
    @Published var notePath: String {
        didSet { defaults.set(notePath, forKey: "notePath"); reload(force: true) }
    }
    @Published var sectionName: String {
        didSet { defaults.set(sectionName, forKey: "section") }
    }
    @Published var showTags: Bool {
        didSet { defaults.set(showTags, forKey: "showTags") }
    }
    @Published var sort: Sort {
        didSet { defaults.set(sort.rawValue, forKey: "sort") }
    }
    /// L("Комментарий для агента", "Comment for the agent"): drafts live here until the task is closed or cancelled, then go into its line.
    // ponytail: keyed by task title, so editing the task text orphans its draft
    @Published var comments: [String: String] {
        didSet { defaults.set(comments, forKey: "comments") }
    }
    @Published var agentComment: Bool {
        didSet { defaults.set(agentComment, forKey: "agentComment") }
    }
    /// Collapsed groups of a merged section, by block name.
    @Published var collapsed: Set<String> {
        didSet { defaults.set(Array(collapsed), forKey: "collapsed") }
    }
    @Published var lang: String {
        didSet { defaults.set(lang, forKey: "lang"); appLang = lang; reload(force: true) } // section names are localized at parse time
    }
    @Published var recurring: Bool {
        didSet { defaults.set(recurring, forKey: "recurring") }
    }
    @Published var trayIcon: String {
        didSet { defaults.set(trayIcon, forKey: "trayIcon") }
    }
    @Published var listHeight: CGFloat = 200
    private var mtime: Date?
    private var lastDay = ""
    private var timer: Timer?

    /// Injected so the README screenshot mode can run on throwaway settings.
    let defaults: UserDefaults
    /// README screenshot only: title prefix of the task whose panel is drawn open.
    var demoExpanded: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        notePath = defaults.string(forKey: "notePath") ?? ""
        sectionName = defaults.string(forKey: "section") ?? ""
        showTags = defaults.object(forKey: "showTags") as? Bool ?? true
        mergeBlocks = defaults.object(forKey: "mergeBlocks") as? Bool ?? true
        comments = defaults.dictionary(forKey: "comments") as? [String: String] ?? [:]
        agentComment = defaults.object(forKey: "agentComment") as? Bool ?? true
        collapsed = Set(defaults.stringArray(forKey: "collapsed") ?? [])
        let savedLang = defaults.string(forKey: "lang") ?? (Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en")
        lang = savedLang
        appLang = savedLang
        recurring = defaults.object(forKey: "recurring") as? Bool ?? true
        trayIcon = defaults.string(forKey: "trayIcon") ?? "scope"
        sort = Sort(rawValue: defaults.string(forKey: "sort") ?? "") ?? .due
        reload()
        refreshReminders()
        // ponytail: 3s mtime poll instead of FSEvents; atomic saves replace the inode and break fd watchers
        timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.reload() }
    }

    var section: Section? { sections.first { $0.name == sectionName } ?? sections.first }
    var visible: [TaskItem] { section?.select(tasks, sort: sort) ?? [] }

    // Search narrows the list on screen only; counters keep showing the whole section.
    @Published var searching = false
    @Published var query = ""
    func matches(_ t: TaskItem) -> Bool {
        let q = query.trimmed
        return !searching || q.isEmpty || t.body.localizedCaseInsensitiveContains(q)
    }
    var shown: [TaskItem] { visible.filter(matches) }

    func reload(force: Bool = false) {
        guard !notePath.isEmpty else { tasks = []; rawSections = []; return }
        let m = (try? FileManager.default.attributesOfItem(atPath: notePath))?[.modificationDate] as? Date
        let today = day() // "today"/"tomorrow" in queries must roll over at midnight
        guard force || m != mtime || today != lastDay else { return }
        mtime = m
        lastDay = today
        guard let text = try? String(contentsOfFile: notePath, encoding: .utf8) else {
            error = L("Не могу прочитать заметку: ", "Can't read the note: ") + notePath // shown once, not on every poll
            return
        }
        (tasks, rawSections) = parseNote(text)
    }

    func apply(_ e: Edit, to t: TaskItem) {
        do {
            var comment: String?
            switch e {
            case .done, .cancel: comment = agentComment ? comments[t.title] : nil
            default: break
            }
            try patchFile(notePath, t, e, comment: comment)
            if comment != nil { comments[t.title] = nil }
            error = nil
            switch e {
            case .done, .cancel, .text: unremind(t)
            default: break
            }
        } catch {
            self.error = (error as? Fail)?.msg ?? error.localizedDescription
        }
        reload(force: true)
    }

    // MARK: Obsidian links

    var vaultRoot: URL {
        let dir = URL(fileURLWithPath: notePath).deletingLastPathComponent()
        var u = dir
        while u.path != "/" && u.path != NSHomeDirectory() {
            if FileManager.default.fileExists(atPath: u.appendingPathComponent(".obsidian").path) { return u }
            u.deleteLastPathComponent()
        }
        return dir
    }

    func obsidianURL(file: String) -> URL? {
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "vault", value: vaultRoot.lastPathComponent), URLQueryItem(name: "file", value: file)]
        return c.url
    }

    func openNote() {
        let rel = String(notePath.dropFirst(vaultRoot.path.count + 1))
        if let u = obsidianURL(file: rel) { NSWorkspace.shared.open(u) }
    }

    func pickNote() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        p.canChooseDirectories = false
        p.message = L("Заметка Obsidian с задачами", "Obsidian note with tasks")
        if !notePath.isEmpty { p.directoryURL = URL(fileURLWithPath: notePath).deletingLastPathComponent() }
        NSApp.activate(ignoringOtherApps: true)
        if p.runModal() == .OK, let u = p.url { notePath = u.path }
    }

    /// Task title with [[wikilinks]] and [md](links) made clickable.
    func rich(_ t: TaskItem) -> AttributedString {
        let s = t.title
        var out = AttributedString()
        let re = try! NSRegularExpression(pattern: "\\[\\[([^\\]|]+)(?:\\|([^\\]]+))?\\]\\]|\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
        var pos = s.startIndex
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            func g(_ n: Int) -> String? { Range(m.range(at: n), in: s).map { String(s[$0]) } }
            out += AttributedString(String(s[pos..<r.lowerBound]))
            var link: AttributedString
            if g(1) != nil {
                pos = r.upperBound // source note: shown as an icon in the status row, see sources()
                continue
            } else {
                let url = g(4) ?? ""
                let target = URL(string: url) ?? url.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed).flatMap(URL.init(string:))
                // Only web links are clickable. Note text is partly machine-collected, and file:, smb: or
                // app-specific schemes can launch things on click.
                if let target, ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
                    link = AttributedString("🌐 " + (g(3) ?? url))
                    link.link = target
                } else {
                    link = AttributedString(g(3) ?? url)
                }
            }
            out += link
            pos = r.upperBound
        }
        out += AttributedString(String(s[pos...]))
        return out
    }

    /// Notes the task links to with [[wikilinks]]: (name, obsidian url).
    func sources(_ t: TaskItem) -> [(String, URL)] {
        allMatches("\\[\\[[^\\]]+\\]\\]", t.title).compactMap { m in
            let target = m.dropFirst(2).dropLast(2).components(separatedBy: "|")[0].components(separatedBy: "#")[0]
            return obsidianURL(file: target).map { (target, $0) }
        }
    }

    // MARK: Reminders
    // ponytail: macOS keeps pending notifications itself, keyed by task title; nothing is written to the note.
    // Editing the task text orphans the key, so apply(.text) drops the reminder.

    func refreshReminders() {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().getPendingNotificationRequests { reqs in
            let ids = Set(reqs.map(\.identifier))
            DispatchQueue.main.async { self.reminders = ids }
        }
    }

    func remind(_ t: TaskItem, at date: Date) {
        guard hasBundle else { error = L("Напоминания работают только из собранного .app", "Reminders only work from the built .app"); return }
        let id = t.title, text = String(rich(t).characters)
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                DispatchQueue.main.async { self.error = L("Уведомления запрещены: Системные настройки → Уведомления → TaskRadarBar", "Notifications are off: System Settings → Notifications → TaskRadarBar") }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = L("Радар задач", "Task radar")
            content.body = text
            content.sound = .default
            // interval trigger: fires even if the picked minute has already started
            let req = UNNotificationRequest(identifier: id, content: content,
                                            trigger: UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false))
            c.add(req) { err in
                DispatchQueue.main.async {
                    if let err { self.error = err.localizedDescription }
                    self.refreshReminders()
                }
            }
        }
    }

    /// Gear menu: fires in 5 seconds, to tell an app bug from Focus / notification settings.
    func testNotification() {
        guard let t = TaskItem.parse("- [ ] " + L("Проверка уведомлений TaskRadarBar", "TaskRadarBar notification test"), line: -1) else { return }
        remind(t, at: Date().addingTimeInterval(5))
    }

    func unremind(_ t: TaskItem) {
        guard hasBundle else { return }
        UNUserNotificationCenter.current().removePendingNotificationRequests(withIdentifiers: [t.title])
        refreshReminders()
    }
}

// MARK: - Views

struct ContentView: View {
    @EnvironmentObject var store: Store
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            if store.searching {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField(L("Поиск по задачам раздела", "Search tasks in this section"), text: $store.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true } }
                        .onExitCommand { store.searching = false; store.query = "" }
                    if !store.query.isEmpty {
                        Text("\(store.shown.count)").font(.caption).foregroundStyle(.secondary)
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help(L("Очистить", "Clear"))
                    }
                }
                .padding(.horizontal, 10)
                .padding(.bottom, 8)
            }
            Divider()

            if let e = store.error {
                HStack(alignment: .top) {
                    Text(e).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button { store.error = nil } label: { Image(systemName: "xmark") }.buttonStyle(.plain)
                }
                .padding(8)
                Divider()
            }

            if store.notePath.isEmpty {
                placeholder(L("Заметка не выбрана", "No note selected")) { Button(L("Выбрать заметку…", "Choose note…")) { store.pickNote() } }
            } else if let e = store.section?.error {
                placeholder(e + "\n" + L("Поправь запрос в заметке или выбери другой раздел.", "Fix the query in the note or pick another section.")) { EmptyView() }
            } else if store.visible.isEmpty {
                placeholder(L("В этом разделе пусто", "Nothing in this section")) { EmptyView() }
            } else if store.shown.isEmpty {
                placeholder(L("Ничего не найдено", "Nothing found")) { EmptyView() }
            } else {
                ScrollView {
                    Group {
                        if store.shown.count <= 40 {
                            VStack(alignment: .leading, spacing: 0) { taskRows }
                        } else {
                            LazyVStack(alignment: .leading, spacing: 0) { taskRows }
                        }
                    }
                    .background(GeometryReader { g in Color.clear.preference(key: HeightKey.self, value: g.size.height) })
                }
                // window height = list height, capped; always a concrete number so the window never guesses
                .frame(height: min(max(store.listHeight, 40), 600))
                .onPreferenceChange(HeightKey.self) { h in
                    DispatchQueue.main.async { if abs(store.listHeight - h) > 0.5 { store.listHeight = h } }
                }
            }
        }
        .frame(width: 480)
    }

    @ViewBuilder var taskRows: some View {
        if let sec = store.section, !sec.children.isEmpty {
            // merged section: one group per original block, e.g. per meeting
            ForEach(sec.children) { c in
                let items = c.select(store.tasks, sort: store.sort).filter(store.matches)
                if !items.isEmpty {
                    // group header: a full-width band; click folds the group. Search shows matches even in folded groups.
                    let folded = store.collapsed.contains(c.name) && !(store.searching && !store.query.trimmed.isEmpty)
                    // the count takes the colour of the group's top priority, same palette as the task flags
                    let top = items.min { prioRank($0.priority) < prioRank($1.priority) }?.priority
                    Button {
                        if store.collapsed.contains(c.name) { store.collapsed.remove(c.name) } else { store.collapsed.insert(c.name) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: folded ? "chevron.right" : "chevron.down")
                                .font(.system(size: 12, weight: .semibold)).frame(width: 14)
                            Text(c.sub ?? c.name).fontWeight(.semibold).lineLimit(1)
                            Spacer()
                            Text("\(items.count)")
                                .fontWeight(prioRank(top) < 3 ? .bold : .regular)
                                .foregroundStyle(prioColor(top))
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(Color.primary.opacity(0.08))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(folded ? L("Развернуть", "Expand") : L("Свернуть", "Collapse"))
                    if folded {
                        Divider()
                    } else {
                        ForEach(items) { t in TaskRow(task: t); Divider() }
                    }
                }
            }
        } else {
            ForEach(store.shown) { t in TaskRow(task: t); Divider() }
        }
    }

    var header: some View {
        HStack(spacing: 10) {
            Menu {
                Picker("", selection: Binding(get: { store.section?.name ?? "" }, set: { store.sectionName = $0 })) {
                    ForEach(store.sections) { s in
                        Text("\(s.name) · \(s.select(store.tasks).count)").tag(s.name)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                // meeting blocks are "Heading › 19:30 - Meeting": the button shows the meeting part
                let name = store.section?.name ?? L("Раздел", "Section")
                Text("\(name.components(separatedBy: " › ").last ?? name) · \(store.visible.count)")
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                store.searching.toggle()
                if !store.searching { store.query = "" }
            } label: {
                Image(systemName: "magnifyingglass").font(.system(size: 16))
                    .foregroundStyle(store.searching ? Color.accentColor : Color.primary)
            }
            .buttonStyle(.plain)
            .help(L("Поиск", "Search"))

            Menu {
                Picker("", selection: $store.sort) {
                    ForEach(Sort.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                Image(systemName: "arrow.up.arrow.down").font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Сортировка", "Sort"))

            Menu {
                if !store.notePath.isEmpty {
                    Text(URL(fileURLWithPath: store.notePath).deletingPathExtension().lastPathComponent)
                    Button(L("Открыть заметку в Obsidian", "Open note in Obsidian")) { store.openNote() }
                }
                Button(L("Выбрать заметку…", "Choose note…")) { store.pickNote() }
                Button(L("Обновить", "Reload")) { store.reload(force: true); store.refreshReminders() }
                Divider()
                Toggle(L("Объединять блоки под одним заголовком", "Merge blocks under one heading"), isOn: $store.mergeBlocks)
                Toggle(L("Показывать теги под задачей", "Show tags under the task"), isOn: $store.showTags)
                Toggle(L("Комментарий для агента", "Comment for the agent"), isOn: $store.agentComment)
                Toggle(L("Повторение задач", "Task recurrence"), isOn: $store.recurring)
                Picker(L("Язык", "Language"), selection: $store.lang) {
                    Text("Русский").tag("ru")
                    Text("English").tag("en")
                }
                Picker(L("Значок в трее", "Menu bar icon"), selection: $store.trayIcon) {
                    Text(L("Прицел", "Scope")).tag("scope")
                    Text(L("Логотип, монохромный", "Logo, monochrome")).tag("mono")
                    Text(L("Логотип, цветной", "Logo, colour")).tag("color")
                }
                Button(L("Проверить уведомление (через 5 секунд)", "Test notification (in 5 seconds)")) { store.testNotification() }
                Toggle(L("Запускать при входе", "Launch at login"), isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { store.error = L("Автозапуск: ", "Launch at login: ") + error.localizedDescription }
                    }))
                Divider()
                // The app itself has no network code; updates are a link opened in the browser.
                if let s = Bundle.main.object(forInfoDictionaryKey: "TRBReleasesURL") as? String, let u = URL(string: s) {
                    Button(L("Обновления: страница релизов ↗", "Updates: releases page ↗")) { NSWorkspace.shared.open(u) }
                }
                Text(L("Версия ", "Version ") + (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"))
                Button(L("Выйти", "Quit")) { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("Настройки", "Settings"))
        }
        .padding(8)
    }

    func placeholder<V: View>(_ text: String, @ViewBuilder _ extra: () -> V) -> some View {
        VStack(spacing: 10) {
            Text(text).foregroundStyle(.secondary).multilineTextAlignment(.center)
            extra()
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
        .padding(.horizontal)
    }
}

struct HeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
}

// CLT without Xcode has no SwiftUIMacros plugin, so @State doesn't compile; row state lives in an ObservableObject.
final class RowState: ObservableObject {
    @Published var hover = false
    @Published var editing = false
    @Published var draft = ""
    @Published var expanded = false
    @Published var picking = false
    @Published var pickDate = Date()
    @Published var reminding = false
    @Published var remindAt = Date()
}

func prioColor(_ p: String?) -> Color {
    switch p {
    case "🔺": return .red
    case "⏫": return .orange
    case "🔼": return .yellow
    case "🔽": return .blue
    case "⏬": return .gray
    default: return .secondary
    }
}

struct TaskRow: View {
    let task: TaskItem
    @EnvironmentObject var store: Store
    @StateObject private var s = RowState()
    @FocusState private var focused: Bool
    @FocusState private var commentFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Button { store.apply(.done, to: task) } label: {
                Image(systemName: "circle").font(.title2).fontWeight(task.priority == nil ? .regular : .semibold)
                    .foregroundStyle(prioColor(task.priority))
            }
            .buttonStyle(.plain)
            .help(L("Закрыть", "Complete"))

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top, spacing: 4) {
                    VStack(alignment: .leading, spacing: 4) {
                if s.editing {
                    TextField("", text: $s.draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($focused)
                        // the field isn't in the window yet when the pencil is clicked, so focus on the next runloop turn
                        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { focused = true } }
                        .onSubmit { store.apply(.text(s.draft), to: task) }
                        .onExitCommand { s.editing = false }
                    Text(L("Enter — сохранить, Esc — отмена. Это вся строка: теги, приоритет и даты тоже здесь.", "Enter saves, Esc cancels. This is the whole line: tags, priority and dates are here too."))
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(store.rich(task))
                        .foregroundStyle(Color(nsColor: .textColor)) // pure black / white: label colour is ~85% and looks grey in a popover
                        .lineLimit(3) // full text: hover tooltip or the pencil
                        .fixedSize(horizontal: false, vertical: true)
                        .help(task.title)
                }
                    }
                    Spacer(minLength: 0)
                    // source note(s): top-right corner, right above the "more" button
                    ForEach(store.sources(task), id: \.1) { name, url in
                        Button { NSWorkspace.shared.open(url) } label: { icon("arrow.up.right.square").padding(.vertical, -4) } // don't make a one-line task taller than its text
                            .buttonStyle(.plain)
                            .help(L("Открыть заметку-источник: ", "Open source note: ") + name)
                            .opacity(rest)
                    }
                    if store.sources(task).isEmpty {
                        // no source note in the task: the button opens the note the task lives in
                        Button { store.openNote() } label: { icon("arrow.up.right.square").padding(.vertical, -4) } // don't make a one-line task taller than its text
                            .buttonStyle(.plain)
                            .help(L("Открыть заметку с задачей: ", "Open the note with this task: ") + URL(fileURLWithPath: store.notePath).deletingPathExtension().lastPathComponent)
                            .opacity(rest)
                    }
                }

                HStack(spacing: 0) {
                    Menu {
                        ForEach([L("🔺 Наивысший", "🔺 Highest"), L("⏫ Высокий", "⏫ High"), L("🔼 Средний", "🔼 Medium"),
                                 L("🔽 Низкий", "🔽 Low"), L("⏬ Самый низкий", "⏬ Lowest")], id: \.self) { p in
                            Button(p) { store.apply(.priority(String(p.prefix(1))), to: task) }
                        }
                        Divider()
                        Button(L("Без приоритета", "No priority")) { store.apply(.priority(nil), to: task) }
                    } label: { icon(task.priority == nil ? "flag" : "flag.fill").foregroundStyle(prioColor(task.priority)) } // outline flag = no priority
                    .help(L("Приоритет", "Priority"))
                    if let d = task.due {
                        Button { togglePicker() } label: {
                            HStack(spacing: 0) {
                                icon("calendar")
                                Text(d.suffix(2) + "." + d.dropFirst(5).prefix(2)).font(.callout).padding(.trailing, 6)
                            }
                            .foregroundStyle(d < day() ? Color.red : d == day() ? Color.orange : Color.secondary)
                        }
                        .help(L("Срок: выбрать другой", "Due date: pick another"))
                    }
                    if store.agentComment {
                        let has = !(store.comments[task.title] ?? "").trimmed.isEmpty
                        Button {
                            // the draft is saved on every keystroke, so closing the panel loses nothing
                            s.expanded.toggle()
                            if s.expanded { DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { commentFocused = true } }
                        } label: {
                            icon(has ? "text.bubble.fill" : "text.bubble").foregroundStyle(has ? Color.orange : Color.primary)
                        }
                        .help(has ? (store.comments[task.title] ?? "") : L("Комментарий для агента", "Comment for the agent"))
                    }
                    if store.showTags {
                        let tags = Text(task.tags.joined(separator: " ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        if task.hasRadarTag {
                            Menu {
                                Button(L("Обычная задача", "Regular task")) { store.apply(.subtag(""), to: task) }
                                Button(L("ask: ждёт решения от меня", "ask: waiting for my decision")) { store.apply(.subtag("/ask"), to: task) }
                                Button(L("wait: висит на других", "wait: blocked on others")) { store.apply(.subtag("/wait"), to: task) }
                            } label: { tags.padding(.leading, 4).frame(height: 26).contentShape(Rectangle()) }
                            .help(L("Тип задачи", "Task type"))
                        } else {
                            tags.padding(.leading, 4)
                        }
                    }
                    Spacer(minLength: 0)
                    actions
                }
                .opacity(rest)
                .buttonStyle(.plain)
                .menuStyle(.button)
                .menuIndicator(.hidden)
                .fixedSize(horizontal: false, vertical: true)

                if s.picking {
                    DatePicker("", selection: $s.pickDate, displayedComponents: .date)
                        .datePickerStyle(.graphical)
                        .labelsHidden()
                    HStack {
                        Button(L("Без срока", "No due date")) { store.apply(.due(nil), to: task) }
                        Spacer()
                        Button(L("Отмена", "Cancel")) { s.picking = false }
                        Button(L("Перенести", "Move")) { store.apply(.due(day(s.pickDate)), to: task) }.keyboardShortcut(.defaultAction)
                    }
                }
                if s.expanded { panel }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { s.hover = $0 }
        .onAppear { if let d = store.demoExpanded, task.title.hasPrefix(d) { s.expanded = true } }
    }

    var actions: some View {
        HStack(spacing: 0) {
            Button { s.draft = task.body; s.editing = true } label: { icon("pencil") }.help(L("Редактировать", "Edit"))
            Button { store.apply(.due(day(addDays(1))), to: task) } label: { icon("sunrise") }.help(L("Перенести на завтра", "Move to tomorrow"))
            if store.recurring {
                Button { s.expanded.toggle() } label: {
                    icon("repeat").foregroundStyle(task.recurrence != nil ? Color.orange : Color.primary)
                }
                .help(task.recurrence.map { L("Повтор: ", "Repeats: ") + $0 } ?? L("Повторение", "Recurrence"))
            }
            // reminder: always here, next to repeat; orange when one is set
            Menu {
                Button(L("Через 1 час", "In 1 hour")) { store.remind(task, at: Date().addingTimeInterval(3600)) }
                Button(L("Завтра в 10:00", "Tomorrow at 10:00")) {
                    store.remind(task, at: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: addDays(1))!)
                }
                Button(L("Своё время…", "Custom time…")) {
                    s.remindAt = Date().addingTimeInterval(3600); s.reminding = true; s.expanded = true
                }
                if store.reminders.contains(task.title) {
                    Divider()
                    Button(L("Убрать напоминание", "Remove reminder")) { store.unremind(task) }
                }
            } label: {
                let on = store.reminders.contains(task.title)
                icon(on ? "bell.fill" : "bell").foregroundStyle(on ? Color.orange : Color.primary)
            }
            .help(L("Напоминание", "Reminder"))
            Button { togglePicker() } label: { icon("calendar") }.help(L("Выбрать срок", "Pick due date"))
            Button { s.expanded.toggle() } label: {
                icon(s.expanded ? "chevron.up" : "ellipsis")
            }.help(L("Приоритет, тип, напоминание, отмена", "Priority, type, reminder, cancel"))
        }
        .buttonStyle(.plain)
    }

    /// Every icon under the task text is dimmed until the row is hovered; the close circle and the text are not.
    var rest: Double { s.hover || s.expanded || s.picking ? 1 : 0.55 }

    /// The one icon size for the whole row: status icons on the left and actions on the right.
    func icon(_ name: String) -> some View {
        Image(systemName: name).font(.system(size: 16)).frame(width: 28, height: 26).contentShape(Rectangle())
    }

    func togglePicker() {
        s.pickDate = task.due.flatMap(dayFmt.date(from:)) ?? Date()
        s.picking.toggle()
    }

    /// All secondary actions in one click each, no nested menus.
    var panel: some View {
        let kind = task.tags.contains("#mod/radar/ask") ? "/ask" : task.tags.contains("#mod/radar/wait") ? "/wait" : ""
        let hasReminder = store.reminders.contains(task.title)
        return VStack(alignment: .leading, spacing: 6) {
            if store.agentComment {
                line(L("Комментарий", "Comment")) {
                    TextField(L("для агента: запишется в задачу при закрытии или отмене", "for the agent: written into the task when it is completed or cancelled"), text: Binding(
                        get: { store.comments[task.title] ?? "" },
                        set: { store.comments[task.title] = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .focused($commentFocused)
                        .onSubmit { s.expanded = false }
                }
            }
            if store.recurring {
                line(L("Повтор", "Repeat")) {
                    ForEach([(L("нет", "none"), ""), (L("день", "day"), "every day"), (L("будни", "Mon–Fri"), "every weekday"), (L("неделя", "week"), "every week"),
                             (L("2 нед", "2 wk"), "every 2 weeks"), (L("месяц", "month"), "every month"), (L("год", "year"), "every year")], id: \.1) { label, rule in
                        chip(label, active: (task.recurrence ?? "") == rule) {
                            store.apply(.recurrence(rule.isEmpty ? nil : rule), to: task)
                        }
                    }
                }
            }
            line(L("Приоритет", "Priority")) {
                ForEach(["🔺", "⏫", "🔼", "", "🔽", "⏬"], id: \.self) { p in
                    chip(p.isEmpty ? L("нет", "none") : p, active: (task.priority ?? "") == p) {
                        store.apply(.priority(p.isEmpty ? nil : p), to: task)
                    }
                }
            }
            if task.hasRadarTag {
                line(L("Тип", "Type")) {
                    chip(L("обычная", "regular"), active: kind == "") { store.apply(.subtag(""), to: task) }
                    chip(L("ask: жду решения я", "ask: my decision"), active: kind == "/ask") { store.apply(.subtag("/ask"), to: task) }
                    chip(L("wait: висит на других", "wait: blocked on others"), active: kind == "/wait") { store.apply(.subtag("/wait"), to: task) }
                }
            }
            line(L("Напомнить", "Remind")) {
                chip(L("через 1 ч", "in 1 h"), active: false) { store.remind(task, at: Date().addingTimeInterval(3600)); s.expanded = false }
                chip(L("завтра 10:00", "tomorrow 10:00"), active: false) {
                    store.remind(task, at: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: addDays(1))!)
                    s.expanded = false
                }
                chip(L("своё…", "custom…"), active: s.reminding) { s.remindAt = Date().addingTimeInterval(3600); s.reminding.toggle() }
                if hasReminder { chip(L("убрать 🔔", "remove 🔔"), active: false) { store.unremind(task) } }
            }
            if s.reminding {
                HStack {
                    DatePicker("", selection: $s.remindAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                    Button(L("Напомнить", "Remind")) { store.remind(task, at: s.remindAt); s.reminding = false; s.expanded = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.leading, 78)
            }
            HStack {
                Button(L("Отменить задачу", "Cancel task")) { store.apply(.cancel, to: task) }
                Spacer()
                Button(L("Заметка в Obsidian ↗", "Note in Obsidian ↗")) { store.openNote() }
            }
        }
        .padding(8)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 6))
    }

    func line<V: View>(_ title: String, @ViewBuilder _ content: () -> V) -> some View {
        HStack(spacing: 4) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 70, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    func chip(_ label: String, active: Bool, _ action: @escaping () -> Void) -> some View {
        // Own look instead of .bordered: never truncates its label, and the active state stays visible
        // even when the window is not key.
        Button(action: action) {
            Text(label)
                .font(.callout)
                .lineLimit(1)
                .fixedSize()
                .padding(.horizontal, 6) // seven "repeat" chips must fit the 480pt window
                .padding(.vertical, 4)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(active ? Color.accentColor : Color(nsColor: .controlColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(active ? 0 : 0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
