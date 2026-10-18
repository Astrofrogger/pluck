import AVFoundation
import QuickLookThumbnailing
import SwiftUI

/// Pluck Studio's one window: a page at a time, with the page bar along the bottom, like an
/// editing program. Only Settings opens a window of its own.
struct StudioWindow: View {
    @Environment(DownloadManager.self) private var manager
    @Environment(AIStudio.self) private var ai
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openPluckSettings) private var openSettings
    @State private var nav = StudioNavigator.shared
    @State private var sideButtons: Any?

    var body: some View {
        VStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            PageBar(nav: nav)
        }
        // Home's glow runs under the whole window: title bar, page and page bar.
        .background {
            if nav.page == .home { BrandGlow().ignoresSafeArea() }
        }
        .modifier(ClearToolbarOnHome(home: nav.page == .home))
        .frame(minWidth: 1120, minHeight: 680)
        .toolbar {
            // (Not on the Photo page: the room goes to the photo. ⌘, still opens Settings.)
            if nav.page != .photo {
                ToolbarItem(placement: .primaryAction) {
                    Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                        .help("Settings (⌘,)")
                }
            }
        }
        .modifier(DownloadSheets())
        .onAppear {
            // Screenshots: -PluckScreenshotPage <page> shows that page.
            if ScreenshotMode.scene != nil, let name = UserDefaults.standard.string(forKey: "PluckScreenshotPage"),
               let page = StudioNavigator.Page(rawValue: name) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 5) { nav.show(page) }
            }
            // The mouse's side buttons go back and forward, as in a browser.
            if sideButtons == nil {
                sideButtons = NSEvent.addLocalMonitorForEvents(matching: .otherMouseDown) { event in
                    switch event.buttonNumber {
                    case 3: nav.goBack(); return nil
                    case 4: nav.goForward(); return nil
                    default: return event
                    }
                }
            }
            // Watched folders: new footage is indexed while Pluck is open.
            FootageFolders.shared.start()
            AppDelegate.openMainWindow = { openWindow(id: "main"); NSApp.activate() }
            AppDelegate.openWindowByID = { nav.open(windowID: $0); openWindow(id: "main"); NSApp.activate() }
        }
        // A link handed over (pluck://, the Share menu) goes to Home's field.
        .onChange(of: manager.pendingLink) { if manager.pendingLink != nil { nav.show(.home) } }
        .onChange(of: ai.searchShown) {
            if ai.searchShown { ai.searchShown = false; nav.show(.search) }
        }
    }

    @ViewBuilder private var page: some View {
        switch nav.page {
        case .home: ContentView()
        case .library: LibraryView()
        case .edit: EditPage(nav: nav)
        case .photo: PhotoPage()
        case .search: VisualSearchView()
        case .tools: ToolsPage(nav: nav)
        }
    }
}

/// On Home the title bar lets the glow through.
private struct ClearToolbarOnHome: ViewModifier {
    let home: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content.toolbarBackgroundVisibility(home ? .hidden : .automatic, for: .windowToolbar)
        } else {
            content
        }
    }
}

// MARK: - Page bar

/// The pages along the bottom of the window (⌘1 to ⌘5).
private struct PageBar: View {
    @Bindable var nav: StudioNavigator
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StudioNavigator.Page.allCases) { page in
                Button { nav.show(page) } label: { item(page) }
                    .buttonStyle(.plain)
                    .keyboardShortcut(page.shortcut, modifiers: .command)
                    .help(Text(page.title))
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(nav.page == .home ? AnyShapeStyle(Color.clear) : AnyShapeStyle(.bar))
        .overlay(alignment: .top) { if nav.page != .home { Divider() } }
    }

    private func item(_ page: StudioNavigator.Page) -> some View {
        let on = nav.page == page
        return VStack(spacing: 3) {
            Image(systemName: page.symbol)
                .font(.system(size: 15, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? AnyShapeStyle(Design.Brand.gradient) : AnyShapeStyle(.secondary))
                .frame(height: 18)
                .overlay(alignment: .topTrailing) {
                    if page == .home, manager.activeCount > 0 {
                        Circle().fill(Color.accentColor).frame(width: 6, height: 6).offset(x: 5, y: -1)
                    }
                }
            Text(page.title)
                .font(.system(size: 10, weight: on ? .semibold : .regular))
                .foregroundStyle(on ? .primary : .secondary)
        }
        .frame(width: 72, height: 40)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(on ? Color.primary.opacity(0.08) : .clear))
        .overlay(alignment: .bottom) {
            if on {
                Capsule().fill(Design.Brand.gradient).frame(width: 22, height: 3).offset(y: 5)
                    .shadow(color: Design.Brand.pink.opacity(0.6), radius: 4)
            }
        }
        .contentShape(.rect)
        .animation(.snappy(duration: 0.2), value: on)
    }
}

// MARK: - Edit

/// The Edit page: the media on the left, the open files in tabs, and the Editor.
private struct EditPage: View {
    @Bindable var nav: StudioNavigator
    @AppStorage("studioMediaShown") private var mediaShown = true
    @AppStorage("studioMediaWidth") private var mediaWidth = 250.0
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            if !nav.tabs.isEmpty {
                TabStrip(nav: nav)
                Divider()
            }
            HStack(spacing: 0) {
                // With a file or project open, the media goes beside its viewer (the timeline
                // runs under both); otherwise it's here.
                if nav.current == nil, mediaShown { mediaColumn }
                VStack(spacing: 0) {
                if let tab = nav.current, let project = tab.project {
                    ProjectView(model: project)
                        .id(tab.id)
                        .environment(\.editMedia, mediaShown ? AnyView(mediaColumn) : nil)
                } else if let tab = nav.current, let target = tab.target, let model = tab.model {
                    EditorView(target: target, model: model)
                        .id(tab.id)
                        .environment(\.editMedia, mediaShown ? AnyView(mediaColumn) : nil)
                } else {
                    VStack(spacing: Design.Spacing.section) {
                        DropZone(symbol: "film", text: Text("Drop a video to edit it, or several to start a project"), targeted: dropTargeted)
                        HStack(spacing: Design.Spacing.controls) {
                            Button("Open…", systemImage: "doc", action: openPanel)
                                .buttonStyle(GlassCapsuleButtonStyle())
                            Button("New Project", systemImage: "rectangle.stack.badge.plus") { nav.newProject() }
                                .buttonStyle(BrandButtonStyle())
                        }
                    }
                    .padding(Design.Spacing.window)
                        .frame(maxWidth: 560, maxHeight: 320)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                }
            }
        }
        .toolbar {
            ToolbarItem(placement: .navigation) {
                Button {
                    withAnimation(.snappy) { mediaShown.toggle() }
                } label: {
                    Label("Media", systemImage: "sidebar.left")
                }
                .help("Show or hide the media (⌥⌘L)")
                .keyboardShortcut("l", modifiers: [.command, .option])
            }
        }
        .navigationTitle(nav.current?.title ?? String(localized: "Edit"))
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var files: [URL] = []
                for provider in providers {
                    if let url = await provider.load(URL.self), url.isFileURL, EditorTarget.canOpen(url) { files.append(url) }
                }
                // Several files make a project; one opens in its own tab.
                if files.count > 1 { nav.newProject(with: files) } else if let file = files.first { nav.open(EditorTarget(path: file.path)) }
            }
            return true
        }
    }

    private var mediaColumn: some View {
        HStack(spacing: 0) {
            MediaPanel(nav: nav)
                .frame(width: mediaWidth)
            ResizeHandle(width: $mediaWidth, range: 200...420, edge: .leading)
        }
        .transition(.move(edge: .leading))
    }

    private func openPanel() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.movie, .audio]
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Open")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { nav.open(EditorTarget(path: url.path)) }
    }
}

/// The files open on the Edit page, as tabs.
private struct TabStrip: View {
    @Bindable var nav: StudioNavigator

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(nav.tabs) { tab in
                    TabChip(title: tab.title, project: tab.project != nil,
                            on: tab.id == nav.current?.id,
                            select: { nav.currentID = tab.id },
                            close: { nav.close(tab.id) },
                            rename: tab.project.map { model in { name in nav.renameProject(model.project.id, to: name) } })
                }
                Menu {
                    Button("New Project", systemImage: "rectangle.stack.badge.plus") { nav.newProject() }
                    Button("Open File…", systemImage: "doc") {
                        let panel = NSOpenPanel()
                        panel.allowedContentTypes = [.movie, .audio]
                        panel.allowsMultipleSelection = true
                        guard panel.runModal() == .OK else { return }
                        for url in panel.urls { nav.open(EditorTarget(path: url.path)) }
                    }
                } label: {
                    Image(systemName: "plus").font(.system(size: 11, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("New project or open a file")
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background(.background.secondary)
    }
}

private struct TabChip: View {
    let title: String
    var project = false
    let on: Bool
    let select: () -> Void
    let close: () -> Void
    /// Projects can be renamed (double-click the tab).
    var rename: ((String) -> Void)?
    @State private var hovering = false
    @State private var editing = false
    @State private var name = ""
    @FocusState private var nameFocused: Bool
    @State private var middleClick: Any?

    var body: some View {
        HStack(spacing: 6) {
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .bold))
            }
            .buttonStyle(.plain)
            .opacity(hovering || on ? 1 : 0)
            .accessibilityLabel("Close")
            .help("Close")
            if project { Image(systemName: "rectangle.stack").font(.caption).foregroundStyle(Design.Brand.gradient) }
            if editing {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .focused($nameFocused)
                    .frame(minWidth: 80, maxWidth: 180)
                    .onSubmit { rename?(name); editing = false }
                    .onExitCommand { editing = false }
                    .onChange(of: nameFocused) { _, focused in if !focused, editing { rename?(name); editing = false } }
            } else {
                Text(title).lineLimit(1).truncationMode(.middle)
            }
        }
        .font(.callout)
        .foregroundStyle(on ? .primary : .secondary)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(on ? Color.primary.opacity(0.1) : hovering ? Color.primary.opacity(0.05) : .clear))
        .overlay(alignment: .bottom) {
            if on { Capsule().fill(Design.Brand.gradient).frame(height: 2).padding(.horizontal, 8) }
        }
        .contentShape(.rect)
        .onTapGesture(count: 2) { startRenaming() }
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .contextMenu {
            if rename != nil { Button("Rename…") { startRenaming() } }
            Button("Close Tab", action: close)
        }
        // The middle mouse button closes a tab, as in a browser.
        .onAppear {
            middleClick = NSEvent.addLocalMonitorForEvents(matching: .otherMouseUp) { event in
                if event.buttonNumber == 2, hovering { close() }
                return event
            }
        }
        .onDisappear {
            if let middleClick { NSEvent.removeMonitor(middleClick) }
            middleClick = nil
        }
    }

    private func startRenaming() {
        guard rename != nil else { return }
        select()
        name = title
        editing = true
        nameFocused = true
    }
}

/// The media to edit: what's downloading, and the Library's videos and songs.
private struct MediaPanel: View {
    @Bindable var nav: StudioNavigator
    @Environment(DownloadManager.self) private var manager
    @State private var library = LibraryStore.shared
    @State private var search = ""
    @State private var projects: [Project] = []
    @State private var folders: [ProjectStore.Folder] = []
    @State private var closedFolders: Set<UUID> = []
    @State private var renaming: Rename?
    @State private var newName = ""
    /// Files that aren't there (deleted, or on a drive that isn't plugged in): left out.
    @State private var missing: Set<String> = []
    /// What the search finds inside the media: what's said and what's seen.
    @State private var moments: [Moment] = []
    @State private var searchingMoments = false

    struct Moment: Identifiable {
        var path: String
        var span: ClosedRange<Double>
        var text: String
        var said: Bool
        var id: String { path + "@\(span.lowerBound)" }
    }

    private var media: [LibraryStore.Entry] {
        let terms = search.trimmingCharacters(in: .whitespaces).lowercased()
        return library.entries
            .filter { ($0.kind == .video || $0.kind == .audio) && !missing.contains($0.path)
                && (terms.isEmpty || $0.title.lowercased().contains(terms)) }
            .sorted { $0.added > $1.added }
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneSearchField(prompt: "Search media", text: $search)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    let active = manager.items.filter(\.isActive)
                    if !active.isEmpty {
                        SidebarSection(title: Text("Downloading")) {
                            ForEach(active) { item in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(item.title).font(.callout).lineLimit(1)
                                    ProgressView(value: item.progress).controlSize(.small)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                            }
                        }
                        .padding(.bottom, 8)
                    }
                    if !projects.isEmpty || !folders.isEmpty {
                        SidebarSection(title: Text("Projects")) {
                            ForEach(folders) { folder in
                                let open = !closedFolders.contains(folder.id)
                                SidebarRow(symbol: open ? "folder" : "folder.fill", title: Text(folder.name),
                                           detail: Text(verbatim: "\(projects.filter { $0.folder == folder.id }.count)"), selected: false) {
                                    EmptyView()
                                }
                                .onTapGesture { if open { closedFolders.insert(folder.id) } else { closedFolders.remove(folder.id) } }
                                .contextMenu {
                                    Button("Rename…") { newName = folder.name; renaming = .folder(folder.id) }
                                    Button("New Project") { let p = nav.newProject(); nav.fileProject(p.id, in: folder.id) }
                                    Divider()
                                    Button("Delete Folder", role: .destructive) {
                                        for project in projects where project.folder == folder.id { nav.fileProject(project.id, in: nil) }
                                        folders.removeAll { $0.id == folder.id }
                                        ProjectStore.saveFolders(folders)
                                    }
                                }
                                .dropDestination(for: String.self) { ids, _ in
                                    for id in ids.compactMap(UUID.init(uuidString:)) { nav.fileProject(id, in: folder.id) }
                                    return true
                                }
                                if open {
                                    ForEach(projects.filter { $0.folder == folder.id }) { projectRow($0).padding(.leading, 14) }
                                }
                            }
                            ForEach(projects.filter { project in project.folder == nil || !folders.contains { $0.id == project.folder } }) { projectRow($0) }
                        }
                        .padding(.bottom, 8)
                    }
                    if let project = nav.current?.project, !project.project.clips.isEmpty {
                        timelineIndex(project)
                    }
                    if searchingMoments || !moments.isEmpty {
                        SidebarSection(title: Text("Moments")) {
                            if searchingMoments, moments.isEmpty {
                                ProgressView().controlSize(.small).padding(8)
                            }
                            ForEach(moments) { moment in momentRow(moment) }
                        }
                        .padding(.bottom, 8)
                    }
                    SidebarSection(title: Text("Media")) {
                        ForEach(media) { entry in
                            MediaRow(entry: entry, on: nav.current?.target?.path == entry.path)
                                .onTapGesture {
                                    // In a project, a click adds the file at the end; elsewhere it opens it.
                                    if let project = nav.current?.project, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                                        Task { await project.add([entry.file]) }
                                    } else {
                                        nav.open(EditorTarget(path: entry.path))
                                    }
                                }
                                .onDrag { NSItemProvider(object: entry.file as NSURL) }
                                .help("Click to open; drag onto a project’s timeline to add it (⌥-click adds it at the end)")
                        }
                    }
                }
                .padding(6)
            }
        }
        .background(.background.secondary)
        .task(id: "\(nav.tabs.count) \(nav.projectsChanged)") {
            projects = ProjectStore.all()
            folders = ProjectStore.folders()
        }
        .contextMenu {
            Button("New Project") { nav.newProject() }
            Button("New Folder") { addFolder() }
        }
        .alert("Rename", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Name", text: $newName)
            Button("Rename") {
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
            Button("Cancel", role: .cancel) { renaming = nil }
        }
        .onAppear {
            // Tests: -PluckScreenshotMediaSearch <words> searches the media.
            if ScreenshotMode.scene != nil, let words = UserDefaults.standard.string(forKey: "PluckScreenshotMediaSearch") { search = words }
        }
        .task(id: search) {
            // Inside the media too, once the search is a word or more (and the typing stops).
            let query = search.trimmingCharacters(in: .whitespaces)
            guard query.count >= 3 else { moments = []; searchingMoments = false; return }
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled else { return }
            searchingMoments = true
            let found = await findMoments(query)
            guard !Task.isCancelled else { return }
            moments = found
            searchingMoments = false
        }
        .task(id: library.entries.count) {
            let paths = library.entries.map(\.path)
            missing = await Task.detached { Set(paths.filter { !FileManager.default.fileExists(atPath: $0) }) }.value
        }
    }
}

extension MediaPanel {
    enum Rename: Equatable { case project(UUID), folder(UUID) }

    /// The open project's clips and titles in order, searchable; a click goes there.
    @ViewBuilder func timelineIndex(_ model: ProjectModel) -> some View {
        let terms = search.trimmingCharacters(in: .whitespaces).lowercased()
        let offsets = model.offsets
        let clips = model.project.clips.enumerated().map { (offsets[$0.offset], $0.element.name, "film") }
        let titles = model.project.titles.map { ($0.start, $0.text, "textformat") }
        let entries = (clips + titles).filter { terms.isEmpty || $0.1.lowercased().contains(terms) }.sorted { $0.0 < $1.0 }
        if !entries.isEmpty {
            SidebarSection(title: Text("Timeline")) {
                ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                    SidebarRow(symbol: entry.2, title: Text(verbatim: entry.1), detail: Text(model.timecode(entry.0)),
                               selected: model.time >= entry.0 - 0.001 && entry.2 == "film" && model.clip(at: model.time).map { offsets[$0.index] == entry.0 } == true) {
                        EmptyView()
                    }
                    .onTapGesture { model.seek(to: entry.0) }
                }
            }
            .padding(.bottom, 8)
        }
    }

    /// The best few moments: what's said (transcripts) and what's seen (looked-at videos).
    func findMoments(_ query: String) async -> [Moment] {
        var found: [Moment] = []
        if let search = AppDelegate.shared?.ai.search {
            for hit in await search.search(query).prefix(6) where hit.available {
                let bite = Self.soundbite(hit.filePath, from: hit.start, terms: hit.terms + query.split(separator: " ").map(String.init))
                found.append(Moment(path: hit.filePath, span: bite.span, text: bite.text ?? hit.text, said: true))
            }
        }
        let indexer = VisualIndexer.shared
        if indexer.indexes.isEmpty { indexer.reload() }
        for hit in VisualIndex.search(query, in: indexer.indexes, limit: 6) where FileManager.default.fileExists(atPath: hit.path) {
            found.append(Moment(path: hit.path, span: hit.shot.start...hit.shot.end, text: hit.shot.description, said: false))
        }
        return found
    }

    /// The sentence a hit is in (where its words were found, at most 20 seconds), and its text: a
    /// soundbite.
    static func soundbite(_ path: String, from start: Double, terms: [String]) -> (span: ClosedRange<Double>, text: String?) {
        guard let words = TranscriptStore.find(forFile: path)?.words, !words.isEmpty else { return (start...(start + 10), nil) }
        let wanted = terms.map { $0.lowercased().trimmingCharacters(in: .punctuationCharacters) }.filter { $0.count >= 3 }
        func ends(_ word: Transcript.Word) -> Bool { word.t.trimmingCharacters(in: .whitespaces).last.map { ".!?…".contains($0) } ?? false }
        // The first word of the passage that matches.
        let from = words.firstIndex { $0.s >= start - 0.05 } ?? 0
        var hit = from
        for index in from..<words.count where words[index].s < start + 25 {
            let word = words[index].t.lowercased()
            if wanted.contains(where: { word.contains($0) || $0.contains(word.trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))) && word.count > 3 }) {
                hit = index
                break
            }
        }
        // Back to where its sentence starts, on to where it ends.
        var first = hit
        while first > 0, !ends(words[first - 1]), words[hit].s - words[first - 1].s < 12 { first -= 1 }
        var last = hit
        while last + 1 < words.count, !ends(words[last]), words[last + 1].e - words[first].s < 20 { last += 1 }
        let text = words[first...last].map(\.t).joined().trimmingCharacters(in: .whitespaces)
        return (max(words[first].s - 0.15, 0)...(words[last].e + 0.2), text)
    }

    func momentRow(_ moment: Moment) -> some View {
        let name = URL(fileURLWithPath: moment.path).deletingPathExtension().lastPathComponent
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: moment.said ? "quote.bubble" : "eye")
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(moment.text).font(.callout).lineLimit(2)
                Text(verbatim: "\(name) · \(Format.duration(moment.span.lowerBound))").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .contentShape(.rect)
        .onTapGesture {
            // In a project, ⌥-click adds the moment at the end; otherwise it opens there.
            if let project = nav.current?.project, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                Task { await project.add([ProjectModel.moment(moment.path, moment.span)]) }
            } else {
                EditorModel.startRange = (moment.span.lowerBound, moment.span.upperBound)
                nav.open(EditorTarget(path: moment.path))
            }
        }
        .onDrag { NSItemProvider(object: ProjectModel.moment(moment.path, moment.span) as NSURL) }
        .help("Click to open it there; drag onto a project’s timeline to add just this moment (⌥-click adds it at the end)")
    }

    func projectRow(_ project: Project) -> some View {
        // An open project's name and length as they are now.
        let live = nav.tabs.first { $0.project?.project.id == project.id }?.project?.project ?? project
        return SidebarRow(symbol: "rectangle.stack", title: Text(live.name), detail: Text(Format.duration(live.duration)),
                          selected: nav.current?.project?.project.id == project.id) {
            EmptyView()
        }
        .onTapGesture { nav.open(project) }
        .draggable(project.id.uuidString)
        .contextMenu {
            Button("Rename…") { newName = live.name; renaming = .project(project.id) }
            if !folders.isEmpty {
                Menu("Move to Folder") {
                    ForEach(folders) { folder in Button(folder.name) { nav.fileProject(project.id, in: folder.id) } }
                    if live.folder != nil {
                        Divider()
                        Button("None") { nav.fileProject(project.id, in: nil) }
                    }
                }
            }
            Button("New Folder") { addFolder() }
            Divider()
            Button("Move to Trash", role: .destructive) { nav.trashProject(project.id) }
        }
    }

    func addFolder() {
        let folder = ProjectStore.Folder(name: String(localized: "New Folder"))
        folders.append(folder)
        ProjectStore.saveFolders(folders)
        newName = folder.name
        renaming = .folder(folder.id)
    }
}

private struct MediaRow: View {
    let entry: LibraryStore.Entry
    let on: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FileThumbnail(file: entry.file, remote: entry.thumbnail, audio: entry.kind == .audio)
                .frame(width: 56, height: 32)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.callout).lineLimit(1)
                if let duration = entry.duration {
                    Text(Format.duration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(on ? AnyShapeStyle(Design.Brand.gradient.opacity(0.28)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0))))
        .contentShape(.rect)
        .onHover { hovering = $0 }
        .help(entry.title)
    }
}

/// A small picture of a file: its saved thumbnail, or one Quick Look makes.
struct FileThumbnail: View {
    let file: URL
    var remote: URL?
    var audio = false
    @State private var image: NSImage?

    var body: some View {
        // The picture fills the frame it's given, cut to it, never wider.
        Color.primary.opacity(0.08)
            .overlay {
                if let image {
                    Image(nsImage: image).resizable().scaledToFill()
                } else {
                    Image(systemName: audio ? "waveform" : "film").foregroundStyle(.tertiary)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
        .task(id: file) {
            if let remote, remote.isFileURL, let saved = NSImage(contentsOf: remote) { image = saved; return }
            let request = QLThumbnailGenerator.Request(fileAt: file, size: CGSize(width: 160, height: 90),
                                                       scale: 2, representationTypes: .thumbnail)
            image = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).nsImage
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tools

/// The Tools page: every tool as a tile, and the one that's open.
private struct ToolsPage: View {
    @Bindable var nav: StudioNavigator

    private var tools: [PluckTool] { PluckTool.allCases.filter { $0 != .library && $0 != .findShots } }

    var body: some View {
        if let tool = nav.tool {
            toolView(tool)
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        if let back = nav.toolBack {
                            Button(action: back.action) { Label(back.title, systemImage: "chevron.left") }
                                .help("Back to the folder (Esc)")
                        } else {
                            Button { nav.tool = nil } label: { Label("Tools", systemImage: "chevron.left") }
                                .help("All tools")
                        }
                    }
                }
        } else {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200, maximum: 280), spacing: 18)], spacing: 18) {
                    ForEach(tools) { tool in
                        Button { nav.tool = tool } label: { ToolTile(tool: tool) }
                            .buttonStyle(.plain)
                            .help(Text(tool.detail))
                    }
                }
                .padding(32)
                .frame(maxWidth: 900)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("Tools")
        }
    }

    @ViewBuilder private func toolView(_ tool: PluckTool) -> some View {
        switch tool {
        case .derush: DerushView()
        case .offload: OffloadView()
        case .rawPlayer: RawPlayerView()
        case .liveRecorder: LiveRecorderView()
        case .deliveryCheck: DeliveryCheckView()
        case .logoAnimator: LogoAnimatorView()
        case .brandPack: BrandPackView()
        case .musicFit: MusicFitView()
        case .officeRender: OfficeRenderView()
        case .library, .findShots: EmptyView()
        }
    }
}

private struct ToolTile: View {
    let tool: PluckTool
    @State private var hovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Image(systemName: tool.symbol)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 46, height: 46)
                .background(tool.tint.gradient, in: .rect(cornerRadius: 12))
                .shadow(color: tool.tint.opacity(hovering ? 0.6 : 0.3), radius: hovering ? 12 : 6, y: 4)
            Text(tool.name).font(.headline)
        }
        .padding(16)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .fill(LinearGradient(colors: [tool.tint.opacity(hovering ? 0.22 : 0.12), Color.primary.opacity(0.03)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Design.Radius.card, style: .continuous)
                .strokeBorder(tool.tint.opacity(hovering ? 0.5 : 0.15), lineWidth: 1)
        }
        .scaleEffect(hovering ? 1.02 : 1)
        .animation(.snappy(duration: 0.18), value: hovering)
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}
