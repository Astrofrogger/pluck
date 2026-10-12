import SwiftUI

/// Where Pluck Studio's one window is: the page shown, the files open on the Edit page, and the
/// tool open on the Tools page. Everything that used to open a window comes here instead.
@MainActor
@Observable
final class StudioNavigator {
    static let shared = StudioNavigator()

    enum Page: String, CaseIterable, Identifiable {
        case home, library, edit, search, tools
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .home: "Home"
            case .library: "Library"
            case .edit: "Edit"
            case .search: "Search"
            case .tools: "Tools"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house"
            case .library: "books.vertical"
            case .edit: "film"
            case .search: "sparkle.magnifyingglass"
            case .tools: "square.grid.2x2"
            }
        }

        var shortcut: KeyEquivalent { KeyEquivalent(Character("\((Page.allCases.firstIndex(of: self) ?? 0) + 1)")) }
    }

    /// A file open on the Edit page, with everything done to it so far.
    @MainActor
    final class Tab: Identifiable {
        let id = UUID()
        let target: EditorTarget
        let model: EditorModel

        init(target: EditorTarget) {
            self.target = target
            model = EditorModel(file: target.file)
        }
    }

    var page: Page = .home
    private(set) var tabs: [Tab] = []
    var currentID: Tab.ID?
    /// The tool open on the Tools page (nil: the list of tools).
    var tool: PluckTool?
    /// Files edited lately, newest first, for Home.
    private(set) var recent: [String] = UserDefaults.standard.stringArray(forKey: recentKey) ?? []

    /// When each of those was last opened.
    private(set) var recentDates: [String: Date] = (UserDefaults.standard.dictionary(forKey: recentDatesKey) as? [String: Date]) ?? [:]

    private static let recentKey = "studioRecentEdits"
    private static let recentDatesKey = "studioRecentEditDates"

    var current: Tab? { tabs.first { $0.id == currentID } ?? tabs.last }

    func show(_ page: Page) {
        self.page = page
    }

    /// Opens the file in a tab on the Edit page (or goes to its tab when it's open), at a
    /// moment if given.
    func open(_ target: EditorTarget, at start: Double? = nil) {
        if let tab = tabs.first(where: { $0.target.path == target.path }) {
            currentID = tab.id
            if let start { tab.model.seek(to: start) }
        } else {
            let tab = Tab(target: target)
            tab.model.startAt = start
            tabs.append(tab)
            currentID = tab.id
        }
        remember(target.path)
        page = .edit
    }

    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].model.close()
        tabs.remove(at: index)
        if currentID == id { currentID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    func open(_ tool: PluckTool) {
        switch tool {
        case .library: page = .library
        case .findShots: page = .search
        default:
            self.tool = tool
            page = .tools
        }
    }

    /// A window that used to open on its own, by its id.
    func open(windowID: String) {
        if let tool = PluckTool(rawValue: windowID) { open(tool) } else if windowID == "main" { page = .home }
    }

    private func remember(_ path: String) {
        recent.removeAll { $0 == path }
        recent.insert(path, at: 0)
        recent = Array(recent.prefix(12))
        recentDates[path] = .now
        recentDates = recentDates.filter { recent.contains($0.key) }
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
        UserDefaults.standard.set(recentDates, forKey: Self.recentDatesKey)
    }

    /// The Library on one of its collections.
    func showLibrary(_ collection: LibraryView.Collection) {
        LibraryView.startCollection = collection
        page = .library
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { LibraryView.startCollection = nil }
    }

    func forget(_ path: String) {
        recent.removeAll { $0 == path }
        UserDefaults.standard.set(recent, forKey: Self.recentKey)
    }
}
