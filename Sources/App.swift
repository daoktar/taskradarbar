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
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

/// Status item + NSPopover. SwiftUI's MenuBarExtra(.window) can't follow a changing content height:
/// it resizes from the bottom-left corner and leaves transparent gaps. A popover resizes anchored to the icon.
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    let store = Store()
    let popover = NSPopover()
    var item: NSStatusItem!
    var sub: AnyCancellable?
    var shownIcon = ""

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
        store.reload()
        store.refreshReminders()
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()
    }

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
        didSet { UserDefaults.standard.set(mergeBlocks, forKey: "mergeBlocks") }
    }
    var sections: [Section] { mergeBlocks ? mergeSections(rawSections) : rawSections }
    @Published var error: String?
    @Published var reminders: Set<String> = []
    @Published var notePath: String {
        didSet { UserDefaults.standard.set(notePath, forKey: "notePath"); reload(force: true) }
    }
    @Published var sectionName: String {
        didSet { UserDefaults.standard.set(sectionName, forKey: "section") }
    }
    @Published var showTags: Bool {
        didSet { UserDefaults.standard.set(showTags, forKey: "showTags") }
    }
    @Published var sort: Sort {
        didSet { UserDefaults.standard.set(sort.rawValue, forKey: "sort") }
    }
    /// "Комментарий для агента": drafts live here until the task is closed or cancelled, then go into its line.
    // ponytail: keyed by task title, so editing the task text orphans its draft
    @Published var comments: [String: String] {
        didSet { UserDefaults.standard.set(comments, forKey: "comments") }
    }
    @Published var agentComment: Bool {
        didSet { UserDefaults.standard.set(agentComment, forKey: "agentComment") }
    }
    /// Collapsed groups of a merged section, by block name.
    @Published var collapsed: Set<String> {
        didSet { UserDefaults.standard.set(Array(collapsed), forKey: "collapsed") }
    }
    @Published var recurring: Bool {
        didSet { UserDefaults.standard.set(recurring, forKey: "recurring") }
    }
    @Published var trayIcon: String {
        didSet { UserDefaults.standard.set(trayIcon, forKey: "trayIcon") }
    }
    @Published var listHeight: CGFloat = 200
    private var mtime: Date?
    private var lastDay = ""
    private var timer: Timer?

    init() {
        notePath = UserDefaults.standard.string(forKey: "notePath") ?? ""
        sectionName = UserDefaults.standard.string(forKey: "section") ?? ""
        showTags = UserDefaults.standard.object(forKey: "showTags") as? Bool ?? true
        mergeBlocks = UserDefaults.standard.object(forKey: "mergeBlocks") as? Bool ?? true
        comments = UserDefaults.standard.dictionary(forKey: "comments") as? [String: String] ?? [:]
        agentComment = UserDefaults.standard.object(forKey: "agentComment") as? Bool ?? true
        collapsed = Set(UserDefaults.standard.stringArray(forKey: "collapsed") ?? [])
        recurring = UserDefaults.standard.object(forKey: "recurring") as? Bool ?? true
        trayIcon = UserDefaults.standard.string(forKey: "trayIcon") ?? "scope"
        sort = Sort(rawValue: UserDefaults.standard.string(forKey: "sort") ?? "") ?? .due
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
            error = "Не могу прочитать заметку: \(notePath)" // shown once, not on every poll
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
        p.message = "Заметка Obsidian с задачами"
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
        guard hasBundle else { error = "Напоминания работают только из собранного .app"; return }
        let id = t.title, text = String(rich(t).characters)
        let c = UNUserNotificationCenter.current()
        c.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            guard granted else {
                DispatchQueue.main.async { self.error = "Уведомления запрещены: Системные настройки → Уведомления → TaskRadarBar" }
                return
            }
            let content = UNMutableNotificationContent()
            content.title = "Радар задач"
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
        guard let t = TaskItem.parse("- [ ] Проверка уведомлений TaskRadarBar", line: -1) else { return }
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
                    TextField("Поиск по задачам раздела", text: $store.query)
                        .textFieldStyle(.plain)
                        .focused($searchFocused)
                        .onAppear { DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { searchFocused = true } }
                        .onExitCommand { store.searching = false; store.query = "" }
                    if !store.query.isEmpty {
                        Text("\(store.shown.count)").font(.caption).foregroundStyle(.secondary)
                        Button { store.query = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).foregroundStyle(.secondary).help("Очистить")
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
                placeholder("Заметка не выбрана") { Button("Выбрать заметку…") { store.pickNote() } }
            } else if let e = store.section?.error {
                placeholder(e + "\nПоправь запрос в заметке или выбери другой раздел.") { EmptyView() }
            } else if store.visible.isEmpty {
                placeholder("В этом разделе пусто") { EmptyView() }
            } else if store.shown.isEmpty {
                placeholder("Ничего не найдено") { EmptyView() }
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
                    .help(folded ? "Развернуть" : "Свернуть")
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
                let name = store.section?.name ?? "Раздел"
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
            .help("Поиск")

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
            .help("Сортировка")

            Menu {
                if !store.notePath.isEmpty {
                    Text(URL(fileURLWithPath: store.notePath).deletingPathExtension().lastPathComponent)
                    Button("Открыть заметку в Obsidian") { store.openNote() }
                }
                Button("Выбрать заметку…") { store.pickNote() }
                Button("Обновить") { store.reload(force: true); store.refreshReminders() }
                Divider()
                Toggle("Объединять блоки под одним заголовком", isOn: $store.mergeBlocks)
                Toggle("Показывать теги под задачей", isOn: $store.showTags)
                Toggle("Комментарий для агента", isOn: $store.agentComment)
                Toggle("Повторение задач", isOn: $store.recurring)
                Picker("Значок в трее", selection: $store.trayIcon) {
                    Text("Прицел").tag("scope")
                    Text("Логотип, монохромный").tag("mono")
                    Text("Логотип, цветной").tag("color")
                }
                Button("Проверить уведомление (через 5 секунд)") { store.testNotification() }
                Toggle("Запускать при входе", isOn: Binding(
                    get: { SMAppService.mainApp.status == .enabled },
                    set: { on in
                        do { if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() } }
                        catch { store.error = "Автозапуск: \(error.localizedDescription)" }
                    }))
                Divider()
                // The app itself has no network code; updates are a link opened in the browser.
                if let s = Bundle.main.object(forInfoDictionaryKey: "TRBReleasesURL") as? String, let u = URL(string: s) {
                    Button("Обновления: страница релизов ↗") { NSWorkspace.shared.open(u) }
                }
                Text("Версия \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev")")
                Button("Выйти") { NSApp.terminate(nil) }
            } label: {
                Image(systemName: "gearshape").font(.system(size: 16))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Настройки")
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
            .help("Закрыть")

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
                    Text("Enter — сохранить, Esc — отмена. Это вся строка: теги, приоритет и даты тоже здесь.")
                        .font(.caption2).foregroundStyle(.secondary)
                } else {
                    Text(store.rich(task))
                        .lineLimit(3) // full text: hover tooltip or the pencil
                        .fixedSize(horizontal: false, vertical: true)
                        .help(task.title)
                }
                    }
                    Spacer(minLength: 0)
                    // source note(s): top-right corner, right above the "more" button
                    ForEach(store.sources(task), id: \.1) { name, url in
                        Button { NSWorkspace.shared.open(url) } label: { icon("arrow.up.right.square") }
                            .buttonStyle(.plain)
                            .help("Открыть заметку-источник: " + name)
                            .opacity(rest)
                    }
                    if store.sources(task).isEmpty {
                        // no source note in the task: the button opens the note the task lives in
                        Button { store.openNote() } label: { icon("arrow.up.right.square") }
                            .buttonStyle(.plain)
                            .help("Открыть заметку с задачей: " + URL(fileURLWithPath: store.notePath).deletingPathExtension().lastPathComponent)
                            .opacity(rest)
                    }
                }

                HStack(spacing: 0) {
                    Menu {
                        ForEach(["🔺 Наивысший", "⏫ Высокий", "🔼 Средний", "🔽 Низкий", "⏬ Самый низкий"], id: \.self) { p in
                            Button(p) { store.apply(.priority(String(p.prefix(1))), to: task) }
                        }
                        Divider()
                        Button("Без приоритета") { store.apply(.priority(nil), to: task) }
                    } label: { icon(task.priority == nil ? "flag" : "flag.fill").foregroundStyle(prioColor(task.priority)) } // outline flag = no priority
                    .help("Приоритет")
                    if let d = task.due {
                        Button { togglePicker() } label: {
                            HStack(spacing: 0) {
                                icon("calendar")
                                Text(d.suffix(2) + "." + d.dropFirst(5).prefix(2)).font(.callout).padding(.trailing, 6)
                            }
                            .foregroundStyle(d < day() ? Color.red : d == day() ? Color.orange : Color.secondary)
                        }
                        .help("Срок: выбрать другой")
                    }
                    if store.reminders.contains(task.title) {
                        Menu {
                            Button("Перенести: через 1 час") { store.remind(task, at: Date().addingTimeInterval(3600)) }
                            Button("Перенести: завтра в 10:00") {
                                store.remind(task, at: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: addDays(1))!)
                            }
                            Divider()
                            Button("Убрать напоминание") { store.unremind(task) }
                        } label: { icon("bell.fill").foregroundStyle(.orange) }
                        .help("Напоминание")
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
                        .help(has ? (store.comments[task.title] ?? "") : "Комментарий для агента")
                    }
                    if store.showTags {
                        let tags = Text(task.tags.joined(separator: " ")).font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                        if task.hasRadarTag {
                            Menu {
                                Button("Обычная задача") { store.apply(.subtag(""), to: task) }
                                Button("ask: ждёт решения от меня") { store.apply(.subtag("/ask"), to: task) }
                                Button("wait: висит на других") { store.apply(.subtag("/wait"), to: task) }
                            } label: { tags.padding(.leading, 4).frame(height: 26).contentShape(Rectangle()) }
                            .help("Тип задачи")
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
                        Button("Без срока") { store.apply(.due(nil), to: task) }
                        Spacer()
                        Button("Отмена") { s.picking = false }
                        Button("Перенести") { store.apply(.due(day(s.pickDate)), to: task) }.keyboardShortcut(.defaultAction)
                    }
                }
                if s.expanded { panel }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { s.hover = $0 }
    }

    var actions: some View {
        HStack(spacing: 0) {
            Button { s.draft = task.body; s.editing = true } label: { icon("pencil") }.help("Редактировать")
            Button { store.apply(.due(day(addDays(1))), to: task) } label: { icon("sunrise") }.help("Перенести на завтра")
            if store.recurring {
                Button { s.expanded.toggle() } label: {
                    icon("repeat").foregroundStyle(task.recurrence != nil ? Color.orange : Color.primary)
                }
                .help(task.recurrence.map { "Повтор: " + $0 } ?? "Повторение")
            }
            Button { togglePicker() } label: { icon("calendar") }.help("Выбрать срок")
            Button { s.expanded.toggle() } label: {
                icon(s.expanded ? "chevron.up" : "ellipsis")
            }.help("Приоритет, тип, напоминание, отмена")
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
                line("Комментарий") {
                    TextField("для агента: запишется в задачу при закрытии или отмене", text: Binding(
                        get: { store.comments[task.title] ?? "" },
                        set: { store.comments[task.title] = $0.isEmpty ? nil : $0 }), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .focused($commentFocused)
                        .onSubmit { s.expanded = false }
                }
            }
            if store.recurring {
                line("Повтор") {
                    ForEach([("нет", ""), ("день", "every day"), ("будни", "every weekday"), ("неделя", "every week"),
                             ("2 недели", "every 2 weeks"), ("месяц", "every month"), ("год", "every year")], id: \.1) { label, rule in
                        chip(label, active: (task.recurrence ?? "") == rule) {
                            store.apply(.recurrence(rule.isEmpty ? nil : rule), to: task)
                        }
                    }
                }
            }
            line("Приоритет") {
                ForEach(["🔺", "⏫", "🔼", "", "🔽", "⏬"], id: \.self) { p in
                    chip(p.isEmpty ? "нет" : p, active: (task.priority ?? "") == p) {
                        store.apply(.priority(p.isEmpty ? nil : p), to: task)
                    }
                }
            }
            if task.hasRadarTag {
                line("Тип") {
                    chip("обычная", active: kind == "") { store.apply(.subtag(""), to: task) }
                    chip("ask: жду решения я", active: kind == "/ask") { store.apply(.subtag("/ask"), to: task) }
                    chip("wait: висит на других", active: kind == "/wait") { store.apply(.subtag("/wait"), to: task) }
                }
            }
            line("Напомнить") {
                chip("через 1 ч", active: false) { store.remind(task, at: Date().addingTimeInterval(3600)); s.expanded = false }
                chip("завтра 10:00", active: false) {
                    store.remind(task, at: Calendar.current.date(bySettingHour: 10, minute: 0, second: 0, of: addDays(1))!)
                    s.expanded = false
                }
                chip("своё…", active: s.reminding) { s.remindAt = Date().addingTimeInterval(3600); s.reminding.toggle() }
                if hasReminder { chip("убрать 🔔", active: false) { store.unremind(task) } }
            }
            if s.reminding {
                HStack {
                    DatePicker("", selection: $s.remindAt, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                        .datePickerStyle(.stepperField)
                        .labelsHidden()
                    Button("Напомнить") { store.remind(task, at: s.remindAt); s.reminding = false; s.expanded = false }
                        .keyboardShortcut(.defaultAction)
                }
                .padding(.leading, 78)
            }
            HStack {
                Button("Отменить задачу") { store.apply(.cancel, to: task) }
                Spacer()
                Button("Заметка в Obsidian ↗") { store.openNote() }
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
        Button(label, action: action).buttonStyle(.bordered).tint(active ? Color.accentColor : nil)
    }
}
