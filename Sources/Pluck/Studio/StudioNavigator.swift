import SwiftUI

/// Where Pluck Studio's one window is: the page shown, the files open on the Edit page, and the
/// tool open on the Tools page. Everything that used to open a window comes here instead.
@MainActor
@Observable
final class StudioNavigator {
    static let shared = StudioNavigator()

    enum Page: String, CaseIterable, Identifiable {
        case home, library, edit, photo, search, tools
        var id: String { rawValue }

        var title: LocalizedStringKey {
            switch self {
            case .home: "Home"
            case .library: "Library"
            case .edit: "Edit"
            case .photo: "Photo"
            case .search: "Search"
            case .tools: "Tools"
            }
        }

        var symbol: String {
            switch self {
            case .home: "house"
            case .library: "books.vertical"
            case .edit: "film"
            case .photo: "camera.aperture"
            case .search: "sparkle.magnifyingglass"
            case .tools: "square.grid.2x2"
            }
        }

        var shortcut: KeyEquivalent { KeyEquivalent(Character("\((Page.allCases.firstIndex(of: self) ?? 0) + 1)")) }
    }

    /// A file open on the Edit page (with everything done to it so far), or a project.
    @MainActor
    final class Tab: Identifiable {
        let id = UUID()
        let target: EditorTarget?
        let model: EditorModel?
        let project: ProjectModel?

        init(target: EditorTarget) {
            self.target = target
            model = EditorModel(file: target.file)
            project = nil
        }

        init(project: Project) {
            target = nil
            model = nil
            self.project = ProjectModel(project: project)
        }

        var title: String { project?.project.name ?? target?.file.deletingPathExtension().lastPathComponent ?? "" }
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
        if let tab = tabs.first(where: { $0.target?.path == target.path }) {
            currentID = tab.id
            if let start { tab.model?.seek(to: start) }
        } else {
            let tab = Tab(target: target)
            tab.model?.startAt = start
            tabs.append(tab)
            currentID = tab.id
            AppDelegate.shared?.ai.imported([target.file])
        }
        remember(target.path)
        page = .edit
    }

    func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        tabs[index].model?.close()
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
        remember(Self.projectKey(project.id))
        page = .edit
    }

    /// A new project, with these files on its timeline (in this order).
    @discardableResult
    func newProject(with files: [URL] = [], named name: String? = nil, clips: [ProjectClip]? = nil) -> Project {
        let count = ProjectStore.all().count + 1
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
