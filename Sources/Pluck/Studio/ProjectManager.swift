import Foundation

/// The project manager's work on the projects kept in `ProjectStore` (Edit, nothing open): what a
/// place shows, in which order, and copies in and out. Folders are data (each project records its
/// folder, folders record their parent); the files stay flat in the Projects folder.
extension ProjectStore {
    /// A place in the project manager's sidebar.
    enum Place: Hashable {
        case recent, all, trash
        case folder(UUID)
    }

    enum Sort: String, CaseIterable, Identifiable {
        case name, changed, created, length, resolution
        var id: String { rawValue }

        /// Names A to Z; the rest biggest or newest first.
        var ascendingFirst: Bool { self == .name }
    }

    /// What a place shows: the search (every word, in any order) over the names, in this order.
    /// Recent keeps the order they were opened in.
    static func shown(_ projects: [Project], in place: Place, recent: [UUID] = [], search: String = "",
                      sort: Sort = .changed, ascending: Bool = false, resolutions: [UUID: Double] = [:]) -> [Project] {
        var list: [Project]
        switch place {
        case .all: list = projects.filter { $0.trashed == nil }
        case .trash: list = projects.filter { $0.trashed != nil }
        case .folder(let id): list = projects.filter { $0.trashed == nil && $0.folder == id }
        case .recent:
            let byID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            list = Array(recent.compactMap { byID[$0] }.filter { $0.trashed == nil }.prefix(10))
        }
        let terms = MediaPanel.fold(search).split(whereSeparator: \.isWhitespace).map(String.init)
        if !terms.isEmpty { list = list.filter { project in terms.allSatisfy { MediaPanel.fold(project.name).contains($0) } } }
        guard place != .recent else { return list }
        let forward: (Project, Project) -> Bool = switch sort {
        case .name: { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        case .changed: { $0.modified < $1.modified }
        case .created: { $0.created < $1.created }
        case .length: { $0.duration < $1.duration }
        case .resolution: { resolutions[$0.id] ?? 0 < resolutions[$1.id] ?? 0 }
        }
        return list.sorted { ascending ? forward($0, $1) : forward($1, $0) }
    }

    /// The folders in tree order, each with how deep it is; the folders under a closed one left out.
    static func tree(_ folders: [Folder], closed: Set<UUID> = []) -> [(folder: Folder, depth: Int)] {
        let ids = Set(folders.map(\.id))
        func children(of parent: UUID?, depth: Int) -> [(folder: Folder, depth: Int)] {
            // (A parent that's gone counts as the top.)
            folders.filter { folder in parent == nil ? folder.parent.map { !ids.contains($0) } ?? true : folder.parent == parent }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
                .flatMap { folder in [(folder, depth)] + (closed.contains(folder.id) ? [] : children(of: folder.id, depth: depth + 1)) }
        }
        return children(of: nil, depth: 0)
    }

    /// Whether `folder` can go into `parent` (not into itself or a folder inside it).
    static func canNest(_ folder: UUID, in parent: UUID?, _ folders: [Folder]) -> Bool {
        var at = parent
        var steps = 0
        while let id = at, steps < folders.count + 1 {
            if id == folder { return false }
            at = folders.first { $0.id == id }?.parent
            steps += 1
        }
        return true
    }

    /// Deletes a folder: what was in it (projects and folders) goes up to where it was.
    static func deleteFolder(_ id: UUID, projects: [Project], file: (UUID, UUID?) -> Void) {
        var folders = folders()
        guard let gone = folders.first(where: { $0.id == id }) else { return }
        for project in projects where project.folder == id { file(project.id, gone.parent) }
        for index in folders.indices where folders[index].parent == id { folders[index].parent = gone.parent }
        folders.removeAll { $0.id == id }
        saveFolders(folders)
    }

    /// A copy with a new id next to it (its still too), named "… Copy". The original isn't touched.
    @discardableResult
    static func duplicate(_ id: UUID) -> Project? {
        guard var project = load(id) else { return nil }
        project.id = UUID()
        project.name = String(localized: "\(project.name) Copy")
        project.created = .now
        project.modified = .now
        takeTitles(&project, from: id)
        guard (try? write(project)) != nil else { return nil }
        try? FileManager.default.copyItem(at: thumbnail(for: id), to: thumbnail(for: project.id))
        return project
    }

    /// A copy's own titles: the original's rendered ones copied into its folder and its items
    /// pointed there (older titles are plain videos, with nothing to render them again from, so
    /// pruning the original's would lose them). The Resolve timeline stays the original's.
    private static func takeTitles(_ project: inout Project, from old: UUID) {
        let from = ProjectModel.titleRenders(old), to = ProjectModel.titleRenders(project.id)
        if FileManager.default.fileExists(atPath: from.path) { try? FileManager.default.copyItem(at: from, to: to) }
        let prefix = from.path + "/"
        for t in (project.tracks ?? []).indices {
            for i in project.tracks![t].items.indices where project.tracks![t].items[i].path.hasPrefix(prefix) {
                project.tracks![t].items[i].path = to.path + "/" + project.tracks![t].items[i].path.dropFirst(prefix.count)
            }
        }
        project.resolveTimeline = nil
    }

    /// A `.pluckproject` from elsewhere (dropped on the window), copied in with a new id: never
    /// over a project that's here, and the file itself is left as it is.
    @discardableResult
    static func importProject(_ file: URL) -> Project? {
        guard file.pathExtension == "pluckproject", let data = try? Data(contentsOf: file) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard var project = try? decoder.decode(Project.self, from: data) else { return nil }
        let old = project.id
        project.id = UUID()
        takeTitles(&project, from: old)
        // (Its folder and Trash belong to the Mac it came from.)
        project.folder = nil
        project.trashed = nil
        guard (try? write(project)) != nil else { return nil }
        return project
    }

    /// Moves the projects in the project manager's Trash to the Mac's Trash (never deleted
    /// outright); where they went.
    @discardableResult
    static func emptyTrash() -> [URL] {
        all().filter { $0.trashed != nil }.compactMap { trash($0.id) }
    }
}
