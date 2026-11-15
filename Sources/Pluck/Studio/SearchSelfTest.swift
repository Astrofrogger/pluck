import AppKit

/// Edit ▸ Search (⌘F) opens the search popup over the page shown (-PluckScreenshotSearchTest <log>, with
/// -PluckScreenshotOffscreen so nothing shows; -PluckScreenshotFile <video> for a library item to open):
/// "PASS name" or "FAIL name: detail" lines, then "done".
@MainActor
enum SearchSelfTest {
    static func run(log: String) async {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) { lines.append((ok ? "PASS \(name)" : "FAIL \(name)") + ": \(detail)") }
        let nav = StudioNavigator.shared
        let palette = SearchPalette.shared

        // ⌘F in the menus: Search comes first, before the text Find.
        func items(_ menu: NSMenu?) -> [NSMenuItem] { (menu?.items ?? []).flatMap { [$0] + items($0.submenu) } }
        let commandF = items(NSApp.mainMenu).filter { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == .command }
        check("⌘F is Edit ▸ Search", commandF.first?.title == "Search", "⌘F items: \(commandF.map(\.title))")
        func commandFPressed() {
            guard let item = commandF.first, let menu = item.menu, let index = menu.items.firstIndex(of: item) else { return }
            menu.performActionForItem(at: index)
        }
        var window: NSWindow? { NSApp.windows.first { $0.canBecomeMain && $0.firstResponder is NSText } }
        /// A key typed in the popup's field, as the keyboard sends it.
        func press(_ code: UInt16, _ characters: String, _ modifiers: NSEvent.ModifierFlags = []) async {
            guard let window, let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                                                            windowNumber: window.windowNumber, context: nil, characters: characters,
                                                            charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code) else { return }
            window.sendEvent(event)
            try? await Task.sleep(for: .milliseconds(300))
        }
        func type(_ text: String) async {
            let searched = palette.finished
            palette.query = text
            for _ in 0..<40 where palette.finished == searched { try? await Task.sleep(for: .milliseconds(100)) }
        }
        let down = String(UnicodeScalar(NSDownArrowFunctionKey)!), up = String(UnicodeScalar(NSUpArrowFunctionKey)!)

        // On each page ⌘F opens the same popup, looking everywhere, with no scope switch; Escape closes it.
        while let tab = nav.tabs.first { nav.close(tab.id) }
        for page in [StudioNavigator.Page.home, .library, .edit, .photo, .deliver, .tools] {
            nav.show(page)
            try? await Task.sleep(for: .seconds(2))
            commandFPressed()
            try? await Task.sleep(for: .milliseconds(500))
            let typing = window != nil
            check("⌘F on \(page.rawValue)", palette.shown && palette.page == page && typing && palette.kinds == Set(SearchPalette.Kind.allCases),
                  "shown \(palette.shown), over \(palette.page), field typing \(typing), kinds \(palette.kinds.map(\.rawValue).sorted())")
            check("Same popup on \(page.rawValue)", !palette.hasScope, "scope switch \(palette.hasScope)")
            await press(53, "\u{1b}")
            check("Escape on \(page.rawValue)", !palette.shown, "still shown \(palette.shown)")
            palette.close()
        }

        // Typing filters: a page and a tool by name; nothing for nonsense.
        nav.show(.home)
        try? await Task.sleep(for: .seconds(1))
        commandFPressed()
        try? await Task.sleep(for: .milliseconds(400))
        await type("Offload")
        let kinds = Set(palette.items.map(\.kind))
        check("Typing finds", palette.items.contains { $0.kind == .tool && $0.title == String(localized: "Offload") }, "kinds \(kinds.map(\.rawValue))")
        await type("zqxwvj")
        check("Typing filters", palette.items.isEmpty, "\(palette.items.count) left: \(palette.items.prefix(3).map(\.title))")
        await type("Library")
        let count = palette.items.count
        await press(125, down)
        let moved = palette.selected
        await press(126, up)
        check("Arrow keys move", count >= 2 && moved == 1 && palette.selected == 0, "down to \(moved), up to \(palette.selected), of \(count)")

        // Return opens the chosen tool.
        await type("Offload")
        palette.selected = palette.items.firstIndex { $0.kind == .tool && $0.id == "tool:offload" } ?? 0
        await press(36, "\r")
        check("Return opens a tool", !palette.shown && nav.page == .tools && nav.tool == .offload, "page \(nav.page), tool \(String(describing: nav.tool))")
        nav.tool = nil

        // A project, on the Edit page.
        let project = Project(name: "Search Popup Test")
        ProjectStore.save(project)
        nav.show(.edit)
        try? await Task.sleep(for: .seconds(1))
        commandFPressed()
        try? await Task.sleep(for: .milliseconds(800))
        await type("Search Popup Test")
        let found = palette.items.first?.id == "project:" + project.id.uuidString
        await press(36, "\r")
        check("Return opens a project", found && !palette.shown && nav.page == .edit && nav.current?.project?.project.id == project.id,
              "found \(found), items \(palette.items.map(\.title)), open \(String(describing: nav.current?.title))")
        while let tab = nav.tabs.first { nav.close(tab.id) }
        try? FileManager.default.removeItem(at: ProjectStore.url(for: project.id))

        // A library item, from the Library.
        if let video = UserDefaults.standard.string(forKey: "PluckScreenshotFile") {
            let entry = LibraryStore.Entry(path: video, title: "Search Popup Clip", added: .now)
            LibraryStore.shared.insert(entry)
            nav.show(.library)
            try? await Task.sleep(for: .seconds(2))
            commandFPressed()
            try? await Task.sleep(for: .milliseconds(400))
            await type("Search Popup Clip")
            let hit = palette.items.first?.id == "library:" + video
            await press(36, "\r")
            check("Return opens a library item", hit && !palette.shown && nav.page == .edit && nav.current?.project?.project.origin == video,
                  "found \(hit), items \(palette.items.map(\.title)), page \(nav.page), open \(String(describing: nav.current?.project?.project.origin))")
            while let tab = nav.tabs.first { nav.close(tab.id) }
            LibraryStore.shared.remove([entry])
            check("Remembers the search", (UserDefaults.standard.string(forKey: "recentSearches") ?? "").hasPrefix("Search Popup Clip"), "recent searches")
        } else {
            lines.append("SKIP Return opens a library item: no -PluckScreenshotFile")
        }

        // On the Photo page, a tool found is opened as the Adjust panel's search does.
        nav.show(.photo)
        try? await Task.sleep(for: .seconds(2))
        commandFPressed()
        try? await Task.sleep(for: .milliseconds(400))
        await type("Exposure")
        let light = palette.items.first { $0.id == "section:light" }
        palette.selected = palette.items.firstIndex { $0.id == "section:light" } ?? 0
        await press(36, "\r")
        check("Return opens a photo tool", light != nil && !palette.shown && PhotoEditing.shared.toolQuery == light?.title,
              "items \(palette.items.map(\.title)), tool search \(PhotoEditing.shared.toolQuery)")
        PhotoEditing.shared.toolQuery = ""
        PhotoEditing.shared.findingTool = false

        nav.show(.home)
        lines.append("done")
        try? lines.joined(separator: "\n").appending("\n").write(toFile: log, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
