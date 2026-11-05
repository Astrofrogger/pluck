import AVFoundation
import SwiftUI

/// The Edit page with nothing open: every project, like an editing program's project manager.
/// Recent, All Projects, folders and the Trash on the left; the projects as stills or a list.
struct ProjectManagerView: View {
    @Bindable var nav: StudioNavigator
    var sidebarShown = true
    var dropTargeted = false
    let openFiles: () -> Void

    @AppStorage("projectsSort") private var sort = ProjectStore.Sort.changed
    @AppStorage("projectsAscending") private var ascending = false
    @AppStorage("projectsList") private var listView = false
    @AppStorage("projectsCardSize") private var cardSize = 220.0
    @AppStorage("projectsSidebarWidth") private var sidebarWidth = Design.Sidebar.width
    @State private var place = ProjectStore.Place.all
    @State private var projects: [Project] = []
    @State private var folders: [ProjectStore.Folder] = []
    @State private var closed: Set<UUID> = []
    @State private var selection: UUID?
    @State private var search = ""
    @FocusState private var searchFocused: Bool
    @State private var renaming: MediaPanel.Rename?
    @State private var newName = ""
    @State private var emptying = false
    /// Each project's picture size (its first clip's), for the list; filled in as it's read.
    @State private var sizes: [UUID: CGSize] = [:]
    @State private var columns = 1

    private var recentIDs: [UUID] { nav.recent.compactMap(StudioNavigator.projectID(in:)) }

    private var shown: [Project] {
        ProjectStore.shown(projects, in: place, recent: recentIDs, search: search, sort: sort, ascending: ascending,
                           resolutions: sizes.mapValues { $0.width * $0.height })
    }

    var body: some View {
        HStack(spacing: 0) {
            if sidebarShown {
                sidebar.frame(width: sidebarWidth)
                ResizeHandle(width: $sidebarWidth, range: Design.Sidebar.widthRange, edge: .leading)
            }
            VStack(spacing: 0) {
                bar
                Divider()
                if listView { list } else { grid }
            }
        }
        .background { shortcuts }
        .task(id: nav.projectsChanged) {
            let (made, kept) = await Task.detached(priority: .userInitiated) {
                (ProjectStore.madeProjects(trashed: true), ProjectStore.folders())
            }.value
            projects = made
            folders = kept
            if case .folder(let id) = place, !kept.contains(where: { $0.id == id }) { place = .all }
        }
        .task(id: "\(listView) \(projects.count)") {
            guard listView else { return }
            for project in projects where sizes[project.id] == nil {
                guard let size = await Self.size(of: project) else { continue }
                sizes[project.id] = size
            }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") { rename() }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .confirmationDialog("Empty Trash", isPresented: $emptying) {
            Button("Empty Trash", role: .destructive) {
                ProjectStore.emptyTrash()
                nav.projectsChanged += 1
            }
        } message: {
            Text("The projects go to the Trash on this Mac.")
        }
    }

    // MARK: - Sidebar

    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Projects").font(.headline)
                Spacer()
            }
            .padding(.horizontal, Design.Sidebar.inset + Design.Sidebar.rowPadding)
            .frame(height: Design.Size.control)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                    placeRow(.recent, symbol: "clock", title: Text("Recent"))
                    placeRow(.all, symbol: "rectangle.stack", title: Text("All Projects"))
                    SidebarGap()
                    SidebarSection(title: Text("Folders"), fold: "projectFolders", count: folders.count, pinned: true) {
                        ForEach(ProjectStore.tree(folders, closed: closed), id: \.folder.id) { item in
                            folderRow(item.folder, depth: item.depth)
                        }
                        if folders.isEmpty {
                            SidebarRow(symbol: "folder.badge.plus", title: Text("New Folder"), dimmed: true) { EmptyView() }
                                .onTapGesture { addFolder(in: nil) }
                        }
                    } accessory: {
                        Button { addFolder(in: nil) } label: { Image(systemName: "plus") }
                            .help("New Folder")
                            .accessibilityLabel("New Folder")
                    }
                    SidebarGap()
                    placeRow(.trash, symbol: "trash", title: Text("Trash"))
                        .contextMenu {
                            Button("Empty Trash") { emptying = true }
                                .disabled(!projects.contains { $0.trashed != nil })
                        }
                }
                .panelColumn()
                .padding(.bottom, 20)
            }
        }
        .background(.background.secondary)
    }

    private func count(_ place: ProjectStore.Place) -> Int { ProjectStore.shown(projects, in: place, recent: recentIDs).count }

    private func placeRow(_ place: ProjectStore.Place, symbol: String, title: Text) -> some View {
        let count = count(place)
        return SidebarRow(symbol: symbol, title: title, detail: Text(verbatim: "\(count)"), selected: self.place == place) { EmptyView() }
            .onTapGesture { go(place) }
            .dropDestination(for: String.self) { ids, _ in drop(ids, on: place) }
    }

    private func folderRow(_ folder: ProjectStore.Folder, depth: Int) -> some View {
        let nested = folders.contains { $0.parent == folder.id }
        let open = !closed.contains(folder.id)
        return SidebarRow(symbol: "folder", title: Text(folder.name), detail: Text(verbatim: "\(count(.folder(folder.id)))"),
                          selected: place == .folder(folder.id), indent: depth + 1, open: nested ? open : nil) { EmptyView() }
            // The chevron in the gutter folds what's inside.
            .overlay(alignment: .leading) {
                if nested {
                    Color.clear.contentShape(.rect)
                        .frame(width: Design.Sidebar.rowPadding + 6)
                        .padding(.leading, CGFloat(depth + 1) * Design.Sidebar.indent - 3)
                        .onTapGesture { if open { closed.insert(folder.id) } else { closed.remove(folder.id) } }
                }
            }
            .onTapGesture { go(.folder(folder.id)) }
            .draggable(folder.id.uuidString)
            .dropDestination(for: String.self) { ids, _ in drop(ids, on: .folder(folder.id)) }
            .contextMenu {
                Button("New Folder") { addFolder(in: folder.id) }
                Button("Rename…") { newName = folder.name; renaming = .folder(folder.id) }
                Divider()
                Button("Delete Folder", role: .destructive) {
                    ProjectStore.deleteFolder(folder.id, projects: projects) { nav.fileProject($0, in: $1) }
                    nav.projectsChanged += 1
                }
            }
    }

    private func go(_ place: ProjectStore.Place) {
        self.place = place
        selection = nil
        // (Empty Trash empties all of it: the Trash shows all of it.)
        if place == .trash { search = "" }
    }

    /// Projects (or folders) dropped on a place: filed there, out of a folder, or in the Trash.
    private func drop(_ ids: [String], on place: ProjectStore.Place) -> Bool {
        var moved = false
        for id in ids.compactMap(UUID.init(uuidString:)) {
            if let index = folders.firstIndex(where: { $0.id == id }) {
                let parent: UUID? = switch place {
                case .folder(let into): into
                case .all: nil
                default: id
                }
                guard parent != id, ProjectStore.canNest(id, in: parent, folders) else { continue }
                folders[index].parent = parent
                ProjectStore.saveFolders(folders)
                moved = true
            } else if projects.contains(where: { $0.id == id }) {
                switch place {
                case .folder(let folder): nav.fileProject(id, in: folder)
                case .all: nav.fileProject(id, in: nil)
                case .trash: nav.trashProject(id)
                case .recent: continue
                }
                moved = true
            }
        }
        if moved { nav.projectsChanged += 1 }
        return moved
    }

    private func addFolder(in parent: UUID?) {
        let folder = ProjectStore.Folder(name: String(localized: "New Folder"), parent: parent)
        folders.append(folder)
        ProjectStore.saveFolders(folders)
        if let parent { closed.remove(parent) }
        newName = folder.name
        renaming = .folder(folder.id)
    }

    private func rename() {
        switch renaming {
        case .project(let id): nav.renameProject(id, to: newName)
        case .folder(let id):
            if let index = folders.firstIndex(where: { $0.id == id }), !newName.trimmingCharacters(in: .whitespaces).isEmpty {
                folders[index].name = newName
                ProjectStore.saveFolders(folders)
            }
        case nil: break
        }
        renaming = nil
    }

    // MARK: - The bar

    private var bar: some View {
        HStack(spacing: Design.Spacing.controls) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                TextField("Search", text: $search)
                    .textFieldStyle(.plain)
                    .focused($searchFocused)
                    .onExitCommand { search = ""; searchFocused = false }
            }
            .padding(.horizontal, 10)
            .frame(width: 220, height: 28)
            .background(Capsule().fill(Color.primary.opacity(0.06)))
            .help("Search (⌘F)")
            Spacer(minLength: 0)
            Picker("Sort", selection: $sort) {
                Text("Name").tag(ProjectStore.Sort.name)
                Text("Changed").tag(ProjectStore.Sort.changed)
                Text("Created").tag(ProjectStore.Sort.created)
                Text("Length").tag(ProjectStore.Sort.length)
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            .help("Sort")
            .onChange(of: sort) { ascending = sort.ascendingFirst }
            if !listView {
                Slider(value: $cardSize, in: 160...360)
                    .controlSize(.small)
                    .frame(width: 90)
                    .help("Size")
                    .accessibilityLabel("Size")
            }
            Picker("View", selection: $listView) {
                Image(systemName: "square.grid.2x2").help("Grid").tag(false)
                Image(systemName: "list.bullet").help("List").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            Button(action: openFiles) { Image(systemName: "doc") }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Open…")
                .accessibilityLabel("Open…")
            if place == .trash {
                Button("Empty Trash") { search = ""; emptying = true }
                    .disabled(shown.isEmpty)
            } else {
                Button("New Project", systemImage: "plus") { newProject() }
                    .buttonStyle(BrandButtonStyle(large: false))
            }
        }
        .padding(.horizontal, Design.Spacing.inset)
        .frame(height: Design.Size.control)
    }

    private func newProject() {
        let project = nav.newProject()
        if case .folder(let folder) = place { nav.fileProject(project.id, in: folder) }
    }

    // MARK: - Grid and list

    @ViewBuilder private var empty: some View {
        if !search.isEmpty {
            ContentUnavailableView.search(text: search)
        } else if place == .all {
            DropZone(symbol: "film", text: Text("Drop a video to edit it, or several to start a project"), targeted: dropTargeted)
                .padding(Design.Spacing.window)
                .frame(maxWidth: 560, maxHeight: 320)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Image(systemName: place == .trash ? "trash" : place == .recent ? "clock" : "folder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder private var grid: some View {
        let shown = shown
        if shown.isEmpty {
            empty
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize), spacing: Design.Spacing.section, alignment: .top)],
                              spacing: Design.Spacing.section) {
                        ForEach(shown) { project in
                            ProjectCard(project: project, selected: selection == project.id, generation: nav.projectsChanged)
                                .id(project.id)
                                .onTapGesture(count: 2) { open(project) }
                                .onTapGesture { selection = project.id; searchFocused = false }
                                .draggable(project.id.uuidString)
                                .contextMenu { menu(project) }
                        }
                    }
                    .padding(Design.Spacing.window)
                }
                .onChange(of: selection) { if let selection { withAnimation(.snappy) { scroller.scrollTo(selection) } } }
            }
            .background { Color.clear.contentShape(.rect).onTapGesture { selection = nil } }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                // As the adaptive grid lays them out: as many as fit at the card size, 16 apart.
                let room = width - 2 * Design.Spacing.window + Design.Spacing.section
                columns = max(1, Int(room / (cardSize + Design.Spacing.section)))
            }
        }
    }

    /// A row of the list: the project and the numbers its columns sort by.
    struct Row: Identifiable {
        let project: Project
        let pixels: Double
        var id: UUID { project.id }
        var name: String { project.name }
        var modified: Date { project.modified }
        var created: Date { project.created }
        var duration: Double { project.duration }
    }

    private static let columnKeys: [(ProjectStore.Sort, PartialKeyPath<Row>)] = [
        (.name, \Row.name), (.changed, \Row.modified), (.created, \Row.created), (.length, \Row.duration), (.resolution, \Row.pixels),
    ]

    /// The list's sorted column is the bar's sort.
    private var order: Binding<[KeyPathComparator<Row>]> {
        Binding {
            let way: SortOrder = ascending ? .forward : .reverse
            return switch sort {
            case .name: [KeyPathComparator(\Row.name, order: way)]
            case .changed: [KeyPathComparator(\Row.modified, order: way)]
            case .created: [KeyPathComparator(\Row.created, order: way)]
            case .length: [KeyPathComparator(\Row.duration, order: way)]
            case .resolution: [KeyPathComparator(\Row.pixels, order: way)]
            }
        } set: { comparators in
            guard let first = comparators.first, let key = Self.columnKeys.first(where: { $0.1 == first.keyPath })?.0 else { return }
            sort = key
            ascending = first.order == .forward
        }
    }

    @ViewBuilder private var list: some View {
        let rows = shown.map { Row(project: $0, pixels: sizes[$0.id].map { $0.width * $0.height } ?? 0) }
        if rows.isEmpty {
            empty
        } else {
            Table(of: Row.self, selection: $selection, sortOrder: order) {
                TableColumn("Name", value: \.name) { row in
                    HStack(spacing: 8) {
                        ProjectStill(project: row.project, generation: nav.projectsChanged)
                            .frame(width: 48, height: 27)
                            .clipShape(.rect(cornerRadius: Design.Radius.badge))
                        Text(row.name).lineLimit(1)
                    }
                }
                .width(min: 180, ideal: 280)
                TableColumn("Changed", value: \.modified) { Text($0.modified, format: .dateTime.day().month().year().hour().minute()) }
                TableColumn("Created", value: \.created) { Text($0.created, format: .dateTime.day().month().year()) }
                TableColumn("Length", value: \.duration) { Text(Format.duration($0.duration)).monospacedDigit() }
                    .width(min: 60, ideal: 80)
                TableColumn("Resolution", value: \.pixels) { row in
                    Text(verbatim: sizes[row.id].map { "\(Int($0.width)) × \(Int($0.height))" } ?? "–").monospacedDigit()
                }
                .width(min: 80, ideal: 110)
            } rows: {
                ForEach(rows) { row in TableRow(row).draggable(row.id.uuidString) }
            }
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let project = projects.first(where: { $0.id == id }) { menu(project) }
            } primaryAction: { ids in
                if let id = ids.first, let project = projects.first(where: { $0.id == id }) { open(project) }
            }
        }
    }

    // MARK: - Actions

    private func open(_ project: Project) {
        guard project.trashed == nil else { return }
        nav.open(project)
    }

    /// What's on disk now, for one that's open (its last changes are written first).
    private func flushed(_ id: UUID) -> URL {
        nav.tabs.first { $0.project?.project.id == id }?.project?.save(now: true)
        return ProjectStore.url(for: id)
    }

    @ViewBuilder private func menu(_ project: Project) -> some View {
        if project.trashed != nil {
            Button("Put Back") { nav.putBack(project.id) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([ProjectStore.url(for: project.id)]) }
        } else {
            Button("Open") { open(project) }
            Divider()
            Button("Rename…") { newName = project.name; renaming = .project(project.id) }
            Button("Duplicate") {
                _ = flushed(project.id)
                if let copy = ProjectStore.duplicate(project.id) {
                    nav.projectsChanged += 1
                    selection = copy.id
                }
            }
            Menu("Move to Folder") {
                Button("None") { nav.fileProject(project.id, in: nil) }
                    .disabled(project.folder == nil)
                if !folders.isEmpty { Divider() }
                ForEach(ProjectStore.tree(folders), id: \.folder.id) { item in
                    Button(String(repeating: "    ", count: item.depth) + item.folder.name) { nav.fileProject(project.id, in: item.folder.id) }
                        .disabled(project.folder == item.folder.id)
                }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([flushed(project.id)]) }
            Button("Export Project…") { export(project) }
            Divider()
            Button("Move to Trash", role: .destructive) { trash(project.id) }
        }
    }

    private func trash(_ id: UUID) {
        let list = shown
        if let index = list.firstIndex(where: { $0.id == id }) {
            selection = list.indices.contains(index + 1) ? list[index + 1].id : index > 0 ? list[index - 1].id : nil
        }
        nav.trashProject(id)
    }

    /// A copy of the project's file, where it's asked for (to take to another Mac).
    private func export(_ project: Project) {
        let file = flushed(project.id)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = project.name + ".pluckproject"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Data(contentsOf: file).write(to: url, options: .atomic)
        } catch {
            NSAlert(error: error).runModal()
        }
    }

    /// Return opens, ⌘⌫ moves to the Trash, the arrows move through the grid, ⌘F searches.
    /// (Not while typing in the search field; the list has its own arrows and Return.)
    private var shortcuts: some View {
        let typing = searchFocused || renaming != nil
        return Group {
            Button("") { searchFocused = true }.keyboardShortcut("f")
            Button("") { if let selection { trash(selection) } }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(typing || selection == nil || place == .trash)
            if !listView {
                Button("") { if let project = shown.first(where: { $0.id == selection }) { open(project) } }
                    .keyboardShortcut(.return, modifiers: [])
                    .disabled(typing || selection == nil)
                Button("") { step(-1) }.keyboardShortcut(.leftArrow, modifiers: []).disabled(typing)
                Button("") { step(1) }.keyboardShortcut(.rightArrow, modifiers: []).disabled(typing)
                Button("") { step(-columns) }.keyboardShortcut(.upArrow, modifiers: []).disabled(typing)
                Button("") { step(columns) }.keyboardShortcut(.downArrow, modifiers: []).disabled(typing)
            }
        }
        .opacity(0)
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private func step(_ by: Int) {
        let list = shown
        guard !list.isEmpty else { return }
        guard let at = list.firstIndex(where: { $0.id == selection }) else { selection = list[0].id; return }
        selection = list[min(max(at + by, 0), list.count - 1)].id
    }

    /// The first clip's picture size, upright.
    // shortcut: the first clip's size, not the frame the project is made in (its aspect); read the
    // project's render size if the list needs to be exact.
    nonisolated static func size(of project: Project) async -> CGSize? {
        guard let clip = project.clips.first,
              let track = try? await AVURLAsset(url: clip.file).loadTracks(withMediaType: .video).first,
              let natural = try? await track.load(.naturalSize), let turn = try? await track.load(.preferredTransform) else { return nil }
        let size = natural.applying(turn)
        return CGSize(width: abs(size.width), height: abs(size.height))
    }
}

/// A project as a card: its still, its name, when it was last changed and how long it is.
private struct ProjectCard: View {
    let project: Project
    let selected: Bool
    let generation: Int
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProjectStill(project: project, generation: generation)
                .aspectRatio(16 / 9, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: Design.Radius.thumbnail, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Design.Radius.thumbnail, style: .continuous)
                        .strokeBorder(selected ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.25 : 0.08)),
                                      lineWidth: selected ? 2 : 1)
                }
            Text(project.name)
                .font(.body)
                .lineLimit(1)
                .truncationMode(.middle)
            Text(verbatim: "\(project.modified.formatted(date: .abbreviated, time: .omitted)) · \(Format.duration(project.duration))")
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .help(project.name)
    }
}

/// The project's still (saved when it was last saved or closed), else its first clip's picture,
/// else a placeholder. Read off the main thread.
private struct ProjectStill: View {
    let project: Project
    let generation: Int
    @State private var image: NSImage?

    var body: some View {
        Color.primary.opacity(0.08)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else if let file = project.clips.first?.file {
                    FileThumbnail(file: file)
                } else {
                    Image(systemName: "rectangle.stack").font(.title2).foregroundStyle(.tertiary)
                }
            }
            .clipped()
            .task(id: "\(project.id) \(project.modified) \(generation)") {
                let file = ProjectStore.thumbnail(for: project.id)
                image = await Task.detached(priority: .utility) { NSImage(contentsOf: file) }.value
            }
            .accessibilityHidden(true)
    }
}
