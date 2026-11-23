import SwiftUI
import AppKit
import UniformTypeIdentifiers

// The board is a note in Obsidian (Tasks queries laid out as columns by a CSS snippet, see docs/board.md).
// The app only opens it; it draws no board of its own and creates nothing in the vault.

let boardGuideURL = URL(string: "https://github.com/daoktar/taskradarbar/blob/main/docs/board.md")!

extension Store {
    /// What obsidian://open gets: the note chosen in settings, else the first wikilink of the task note's preamble.
    // ponytail: a linked note is not checked for existence, Obsidian resolves the name; the choice can be replaced, not cleared
    var board: String? {
        if !boardPath.isEmpty {
            guard FileManager.default.fileExists(atPath: boardPath), boardPath.hasPrefix(vaultRoot.path + "/") else { return nil }
            return String(boardPath.dropFirst(vaultRoot.path.count + 1))
        }
        return (try? String(contentsOfFile: notePath, encoding: .utf8)).flatMap(boardLink)
    }

    /// No board known: show how to set one up instead.
    func openBoard() {
        guard let b = board, let u = obsidianURL(file: b) else { boardHelp.toggle(); return }
        boardHelp = false
        NSWorkspace.shared.open(u)
    }

    func pickBoard() {
        let p = NSOpenPanel()
        p.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        p.canChooseDirectories = false
        p.message = L("Obsidian note with the board")
        if !notePath.isEmpty { p.directoryURL = URL(fileURLWithPath: notePath).deletingLastPathComponent() }
        NSApp.activate(ignoringOtherApps: true)
        guard p.runModal() == .OK, let u = p.url else { return }
        // ponytail: the link is built from the task note's vault, so a board in another vault can't be opened
        guard u.path.hasPrefix(vaultRoot.path + "/") else { error = L("The board note must be in the same vault as the task note."); return }
        boardPath = u.path
        boardHelp = false
    }
}

struct BoardHelp: View {
    @EnvironmentObject var store: Store

    // Same look as the task list below: a group-header band, body-size text rows, chip buttons.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Text(L("Board: the same tasks as columns in Obsidian")).fontWeight(.semibold).lineLimit(1)
                Spacer()
                Button { store.boardHelp = false } label: { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                    .buttonStyle(.plain).help(L("Close"))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color.primary.opacity(0.08))
            ForEach([L("1. Install and enable the Tasks plugin in Obsidian."),
                     L("2. Add the CSS snippet from the guide and enable it in Settings → Appearance."),
                     L("3. Create the board note from the template, then link it at the top of the task note or choose it here.")], id: \.self) {
                Text($0)
                    .foregroundStyle(Color(nsColor: .textColor))
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                Divider()
            }
            HStack {
                chip(L("Board setup guide ↗")) { NSWorkspace.shared.open(boardGuideURL) }
                Spacer()
                chip(L("Choose board note…")) { store.pickBoard() }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            Divider()
        }
    }

    /// The chip of the task panel (TaskRow.chip), without the active state.
    func chip(_ label: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label).font(.callout).lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 4)
                .background(Color(nsColor: .controlColor), in: RoundedRectangle(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(Color.primary.opacity(0.15), lineWidth: 0.5))
        }
        .buttonStyle(.plain)
    }
}
