import AppKit

/// Edit ▸ Search (⌘F) goes to the search of the page shown (-PluckScreenshotSearchTest <log>, with
/// -PluckScreenshotOffscreen so nothing shows): "PASS name" or "FAIL name: detail" lines, then "done".
@MainActor
enum SearchSelfTest {
    static func run(log: String) async {
        var lines: [String] = []
        func check(_ name: String, _ ok: Bool, _ detail: String) { lines.append((ok ? "PASS \(name)" : "FAIL \(name)") + ": \(detail)") }
        let nav = StudioNavigator.shared

        // ⌘F in the menus: Search comes first, before the text Find.
        func items(_ menu: NSMenu?) -> [NSMenuItem] { (menu?.items ?? []).flatMap { [$0] + items($0.submenu) } }
        let commandF = items(NSApp.mainMenu).filter { $0.keyEquivalent == "f" && $0.keyEquivalentModifierMask == .command }
        check("⌘F is Edit ▸ Search", commandF.first?.title == "Search", "⌘F items: \(commandF.map(\.title))")

        // Each page with a search field takes it; the others have the command off.
        let expected: [StudioNavigator.Page: Bool] = [.home: true, .library: true, .edit: nav.current == nil, .tools: false]
        for page in [StudioNavigator.Page.home, .library, .edit, .tools, .photo] {
            nav.show(page)
            try? await Task.sleep(for: .seconds(2))
            let asked = nav.searchRequests
            let before = nav.lastSearched
            nav.search()
            try? await Task.sleep(for: .milliseconds(400))
            let routed = nav.canSearch ? nav.lastSearched == page && nav.searchRequests == asked + 1 : nav.searchRequests == asked && nav.lastSearched == before
            let wanted = expected[page].map { $0 == nav.canSearch } ?? true
            let typing = NSApp.windows.contains { $0.canBecomeMain && $0.firstResponder is NSText }
            let responder = NSApp.windows.filter(\.canBecomeMain).map { String(describing: $0.firstResponder.map { type(of: $0) }) }
            check("Search on \(page.rawValue)", routed && wanted && (typing || !nav.canSearch),
                  "can search \(nav.canSearch), went to \(String(describing: nav.lastSearched)), field typing \(typing) \(responder)")
        }
        nav.show(.home)
        lines.append("done")
        try? lines.joined(separator: "\n").appending("\n").write(toFile: log, atomically: true, encoding: .utf8)
        NSApp.terminate(nil)
    }
}
