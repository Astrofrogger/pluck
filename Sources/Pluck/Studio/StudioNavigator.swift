import SwiftUI

/// Where Pluck Studio's one window is: the page shown, the files open on the Edit page, and the
/// tool open on the Tools page. Everything that used to open a window comes here instead.
@MainActor
@Observable
final class StudioNavigator {
    static let shared = StudioNavigator()

    enum Page: String, CaseIterable, Identifiable {
        case home, library, edit, photo, tools
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .home: "Home"
            case .library: "Library"
            case .edit: "Edit"
            case .photo: "Photo"
            case .tools: "Tools"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house"
            case .library: "books.vertical"
            case .edit: "film"
            case .photo: "camera.aperture"
            case .tools: "square.grid.2x2"
            }
        }

        var shortcut: KeyEquivalent { KeyEquivalent(Character("\((Page.allCases.firstIndex(of: self) ?? 0) + 1)")) }
    }

    /// A project open on the Edit page (a file opened is its own project).
    @MainActor
    final class Tab: Identifiable {
        let id = UUID()
        let project: ProjectModel?

        init(project: Project) {
            self.project = ProjectModel(project: project)
        }

        var title: String { project?.project.name ?? "" }
    }

    var page: Page = .home {
        didSet { if oldValue != page { moved(from: Place(page: oldValue, tool: tool)) } }
    }
    private(set) var tabs: [Tab] = []
    var currentID: Tab.ID?
    /// The tool open on the Tools page (nil: the list of tools).
    var tool: PluckTool? {
        didSet { if oldValue != tool { moved(from: Place(page: page, tool: oldValue)) } }
    }
    /// A step back inside the open tool (a clip back to its folder), taken by the back button
    /// before it goes back to all tools.
    var toolBack: (title: String, action: () -> Void)?
    /// And forward again inside it (the folder to the clip that was open).
    var toolForward: (() -> Void)?

    // MARK: - Back and forward (the mouse's side buttons), as in a browser

    /// Where the window was: a page, and on Tools, the tool open.
    private struct Place: Equatable {
        var page: Page
        var tool: PluckTool?
        init(page: Page, tool: PluckTool?) {
            self.page = page
            self.tool = page == .tools ? tool : nil
        }
    }
    private var backward: [Place] = []
    private var forward: [Place] = []
    private var restoring = false
    private var here: Place { Place(page: page, tool: tool) }

    private func moved(from place: Place) {
        guard !restoring, place != here, place != backward.last else { return }
        backward.append(place)
        if backward.count > 50 { backward.removeFirst() }
        forward = []
    }

    private func go(to place: Place) {
        restoring = true
        page = place.page
        if place.page == .tools { tool = place.tool }
        restoring = false
    }

    /// One step back: inside the tool first, then where the window was before.
    func goBack() {
        if page == .library || (page == .tools && tool != nil), let back = toolBack { back.action(); return }
        while let place = backward.popLast() {
            guard place != here else { continue }
            forward.append(here)
            go(to: place)
            return
        }
    }

    func goForward() {
        if page == .library || (page == .tools && tool != nil), let next = toolForward { next(); return }
        while let place = forward.popLast() {
            guard place != here else { continue }
            backward.append(here)
            go(to: place)
            return
        }
    }
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
    func open(_ target: EditorTarget, at start: Double? = nil, range: ClosedRange<Double>? = nil) {
        // The file's own project: its edit, kept as a project of the parts kept.
        let project = tabs.compactMap(\.project).first { $0.project.origin == target.path }?.project ?? ProjectStore.fileProject(for: target.path)
        let opened = !tabs.contains { $0.project?.project.id == project.id }
        open(project)
        if opened { AppDelegate.shared?.ai.imported([target.file]) }
        guard let model = tabs.first(where: { $0.project?.project.id == project.id })?.project else { return }
        Task {
            await model.prepareFile()
            // At a moment of the file (a search hit, a transcript line), or a stretch of it.
            if let range, let from = model.timelineTimes(of: range.lowerBound, in: target.path).first,
               let to = model.timelineTimes(of: max(range.upperBound - 0.001, range.lowerBound), in: target.path).first {
                model.markIn(from)
                model.markOut(to)
                model.seek(to: from)
            } else if let start, let at = model.timelineTimes(of: start, in: target.path).first {
                model.seek(to: at)
            }
        }
    }

    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].project?.close()
        tabs.remove(at: index)
        if currentID == id { currentID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
    }

    // MARK: - Projects

    /// Renames a project, open or not.
    func renameProject(_ id: UUID, to name: String) {
        let name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let model = tabs.first(where: { $0.project?.project.id == id })?.project { model.rename(name) } else { ProjectStore.update(id) { $0.name = name } }
        projectsChanged += 1
    }

    func fileProject(_ id: UUID, in folder: UUID?) {
        if let model = tabs.first(where: { $0.project?.project.id == id })?.project { model.file(in: folder) } else { ProjectStore.update(id) { $0.folder = folder } }
        projectsChanged += 1
    }

    /// Closes it if open and moves it to the Trash.
    func trashProject(_ id: UUID) {
        if let tab = tabs.first(where: { $0.project?.project.id == id }) { close(tab.id) }
        ProjectStore.trash(id)
        projectsChanged += 1
    }

    /// Counts changes to the list of projects, so lists of them reload.
    var projectsChanged = 0

    /// Opens a project in a tab on the Edit page.
    func open(_ project: Project) {
        if let tab = tabs.first(where: { $0.project?.project.id == project.id }) {
            currentID = tab.id
        } else {
            let tab = Tab(project: project)
            tabs.append(tab)
            currentID = tab.id
        }
        // A file's own project is remembered as the file.
        remember(project.origin ?? Self.projectKey(project.id))
        page = .edit
    }

    /// A new project, with these files on its timeline (in this order).
    @discardableResult
    func newProject(with files: [URL] = [], named name: String? = nil, clips: [ProjectClip]? = nil) -> Project {
        let count = ProjectStore.madeProjects().count + 1
        var project = Project(name: name ?? String(localized: "Project \(count)"))
        if let clips { project.clips = clips }
        ProjectStore.save(project)
        open(project)
        if !files.isEmpty, let model = tabs.first(where: { $0.project?.project.id == project.id })?.project {
            Task { await model.add(files) }
            AppDelegate.shared?.ai.imported(files)
        }
        return project
    }

    /// How a project is kept among the files edited lately.
    static func projectKey(_ id: UUID) -> String { "project:" + id.uuidString }

    static func projectID(in key: String) -> UUID? {
        key.hasPrefix("project:") ? UUID(uuidString: String(key.dropFirst("project:".count))) : nil
    }

    func open(_ tool: PluckTool) {
        switch tool {
        case .library: page = .library
        case .findShots:
            // (Search is the Library's search field.)
            LibraryView.focusSearch = true
            page = .library
            NotificationCenter.default.post(name: LibraryView.focusNotification, object: nil)
        case .rawPlayer: page = .library
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
