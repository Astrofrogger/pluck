import AVFoundation
import QuickLookThumbnailing
import SwiftUI

/// Pluck Studio's one window: a page at a time, with the page bar along the bottom, like an
/// editing program. Only Settings opens a window of its own.
struct StudioWindow: View {
    /// The window's own coordinates (from its top left), for views that compare with AppKit events.
    static let space = "studioWindow"
    @Environment(DownloadManager.self) private var manager
    @Environment(AIStudio.self) private var ai
    @Environment(AppUpdater.self) private var appUpdater
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openPluckSettings) private var openSettings
    @State private var nav = StudioNavigator.shared
    @State private var sideButtons: Any?

    var body: some View {
        VStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // The page floats as a rounded panel on the backdrop (brandbook v1); on Home the glow shows through.
                // A background, not a clip: pages that reach under the title bar keep their top.
                // Library draws its own panels (sidebar, grid, details) on the backdrop.
                .background(Design.Studio.panel.opacity([.library, .photo, .edit, .tools].contains(nav.page) ? 0 : 1),
                            in: RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous))
                .padding(.horizontal, Design.Studio.panelGap)
                // An update installing, over every page (Home shows it at its top).
                .overlay(alignment: .bottom) {
                    if appUpdater.status == .installing, nav.page != .home {
                        UpdateBar()
                            .frame(maxWidth: 560)
                            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
                            .padding(Design.Spacing.inset)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
                    }
                }
                .animation(.snappy, value: appUpdater.status == .installing)
            PageBar(nav: nav)
        }
        // Home's glow runs under the whole window: title bar, page and page bar.
        .background {
            Design.Studio.backdrop.ignoresSafeArea()
        }
        .coordinateSpace(name: Self.space)
        // Always dark: neutral dark surroundings for judging colour (owner's choice, 2026-11-12).
        .preferredColorScheme(.dark)
        // What's chosen is plum, never the Mac's blue (segmented controls, tabs, toggles).
        .tint(Design.Brand.pink)
        .modifier(ClearToolbar(clear: nav.page == .photo))
        .frame(minWidth: 1120, minHeight: 680)
        .toolbar {
            // (Not on the Photo page: the room goes to the photo. ⌘, still opens Settings.)
            // (Library puts its own last, after its panel buttons, as in the reference.)
            if ![.photo, .library, .home, .edit].contains(nav.page) {
                ToolbarItem(placement: .primaryAction) {
                    Button { openSettings() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                        .help("Settings (⌘,)")
                }.studioFlat()
            }
        }
        .modifier(DownloadSheets())
        .updatePrompt(appUpdater)
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
            if ai.searchShown { ai.searchShown = false; nav.show(.library) }
        }
    }

    @ViewBuilder private var page: some View {
        switch nav.page {
        case .home: ContentView()
        case .library: LibraryView()
        case .edit: EditPage(nav: nav)
        case .photo: PhotoPage()
        case .tools: ToolsPage(nav: nav)
        }
    }
}

/// The title bar in the backdrop's colour; see-through on Home (the glow) and Photo (its own top
/// row sits there), so pages never scroll up under it.
private struct ClearToolbar: ViewModifier {
    let clear: Bool

    func body(content: Content) -> some View {
        if #available(macOS 15, *) {
            content
                .toolbarBackground(Design.Studio.backdrop, for: .windowToolbar)
                .toolbarBackgroundVisibility(clear ? .hidden : .visible, for: .windowToolbar)
        } else {
            content
        }
    }
}

// MARK: - Page bar

/// The pages along the bottom of the window (⌘1 to ⌘5).
private struct PageBar: View {
    @Bindable var nav: StudioNavigator

    var body: some View {
        HStack(spacing: 4) {
            ForEach(StudioNavigator.Page.allCases) { page in
                PageButton(page: page, nav: nav)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 52)
        .overlay(alignment: .leading) { StudioMark().frame(width: 20, height: 20).padding(.leading, 16) }
        .overlay(alignment: .trailing) {
            HStack(spacing: 12) {
                ExportChip(nav: nav)
                DownloadStatus()
            }
            .padding(.trailing, 16)
        }
    }
}

/// "3 downloading" and a ring for how far they are together, while downloads run; a click goes Home.
private struct DownloadStatus: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        let active = manager.items.filter(\.isActive)
        if !active.isEmpty {
            let done = active.reduce(0) { $0 + $1.progress } / Double(active.count)
            Button { StudioNavigator.shared.show(.home) } label: {
                HStack(spacing: 8) {
                    Text("\(active.count) downloading").font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                    ZStack {
                        Circle().stroke(Design.Studio.line, lineWidth: 2.5)
                        Circle().trim(from: 0, to: max(done, 0.03))
                            .stroke(Design.Brand.pink, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 14, height: 14)
                    .animation(.smooth, value: done)
                }
            }
            .buttonStyle(.plain)
            .help("Show the downloads")
        }
    }
}

/// One page in the bar: icon and name; the page shown is filled with plum and glows softly.
private struct PageButton: View {
    let page: StudioNavigator.Page
    @Bindable var nav: StudioNavigator
    @Environment(DownloadManager.self) private var manager
    @State private var hovering = false

    var body: some View {
        let on = nav.page == page
        Button { nav.show(page) } label: {
            HStack(spacing: 7) {
                Image(systemName: page.symbol)
                    .font(.system(size: 13))
                    .overlay(alignment: .topTrailing) {
                        if page == .home, manager.activeCount > 0 {
                            Circle().fill(Design.Brand.pink).frame(width: 6, height: 6).offset(x: 4, y: -2)
                        }
                    }
                Text(page.title).font(Design.Studio.body)
            }
            .foregroundStyle(on ? Color.white : hovering ? Design.Studio.text : Design.Studio.textQuiet)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                let shape = RoundedRectangle(cornerRadius: Design.Studio.controlRadius, style: .continuous)
                if on {
                    shape.fill(Design.Brand.deep).shadow(color: Design.Brand.pink.opacity(0.5), radius: 6)
                } else if hovering {
                    shape.fill(Design.Studio.raised)
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .keyboardShortcut(page.shortcut, modifiers: .command)
        .help(Text(page.title))
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.2), value: on)
    }
}

/// "Exporting 1 of 2" while a project export runs or waits; a click goes to its Export tab.
private struct ExportChip: View {
    let nav: StudioNavigator

    var body: some View {
        let busy = nav.tabs.compactMap { tab in tab.project.map { (tab, $0.exports) } }.filter { $0.1.jobsLeft > 0 }
        if let (tab, _) = busy.first {
            let total = busy.reduce(0) { $0 + $1.1.batchDone + $1.1.jobsLeft }
            let done = busy.reduce(0) { $0 + $1.1.batchDone }
            Button {
                UserDefaults.standard.set(ProjectInspector.Tab.export.rawValue, forKey: "projectSidebarTab")
                nav.currentID = tab.id
                nav.show(.edit)
            } label: {
                StatusChip(text: Text("Exporting \(done + 1) of \(total)"), colour: .gray, busy: true)
            }
            .buttonStyle(.plain)
            .help("Show the export")
        }
    }
}

// MARK: - Edit

/// The Edit page: the open files in tabs and the Editor; with nothing open, the project manager.
private struct EditPage: View {
    @Bindable var nav: StudioNavigator
    @AppStorage("studioMediaShown") private var mediaShown = true
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            // With a project open, the project; otherwise the project manager. (Its tabs are in the title bar.)
            if let tab = nav.current, let project = tab.project {
                // The project's own media and the libraries are in its panel (EditSidePanel).
                ProjectView(model: project)
                    .id(tab.id)
            } else {
                ProjectManagerView(nav: nav, sidebarShown: mediaShown, dropTargeted: dropTargeted, openFiles: openPanel)
            }
        }
        .toolbar {
            // The open projects and files, right of the window's buttons (layout reference, page 3).
            ToolbarItem(placement: .navigation) {
                TabStrip(nav: nav)
                    .frame(maxWidth: 720, alignment: .leading)
                    .background {
                        // ⌥⌘L still shows or hides the media.
                        Button("") { withAnimation(.snappy) { mediaShown.toggle() } }
                            .keyboardShortcut("l", modifiers: [.command, .option]).opacity(0).accessibilityHidden(true)
                    }
            }.studioFlat()
        }
        .navigationTitle("")
        .onDrop(of: [.fileURL], isTargeted: $dropTargeted) { providers in
            Task { @MainActor in
                var files: [URL] = []
                for provider in providers {
                    guard let url = await provider.load(URL.self), url.isFileURL else { continue }
                    // A project from elsewhere: a copy goes in with the others.
                    if url.pathExtension == "pluckproject" {
                        if ProjectStore.importProject(url) != nil { nav.projectsChanged += 1 }
                    } else if EditorTarget.canOpen(url) { files.append(url) }
                }
                // Several files make a project; one opens in its own tab.
                if files.count > 1 { nav.newProject(with: files) } else if let file = files.first { nav.open(EditorTarget(path: file.path)) }
            }
            return true
        }
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
                .foregroundStyle(Design.Studio.textQuiet)
            }
            .padding(.horizontal, 4)
        }
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
        HStack(spacing: 8) {
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
            Button(action: close) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).foregroundStyle(Design.Studio.textQuiet)
            }
            .buttonStyle(.plain)
            .opacity(hovering || on ? 1 : 0)
            .accessibilityLabel("Close")
            .help("Close")
        }
        .font(Design.Studio.body)
        .foregroundStyle(on ? Design.Studio.text : Design.Studio.textQuiet)
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .frame(height: 28)
        .frame(maxWidth: 220)
        .background(RoundedRectangle(cornerRadius: Design.Studio.controlRadius, style: .continuous)
            .fill(on ? Design.Studio.panel : hovering ? Design.Studio.panel.opacity(0.5) : .clear))
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
struct MediaPanel: View {
    @Bindable var nav: StudioNavigator
    /// Set when it's a picker (Import from Pluck Library): what's chosen is handed here instead of opened.
    var onPick: (([URL]) -> Void)? = nil

    init(nav: StudioNavigator, onPick: (([URL]) -> Void)? = nil) {
        self.nav = nav
        self.onPick = onPick
    }
    @State private var library = LibraryStore.shared
    /// The videos and songs, newest first, each with the words to find it by (made once per
    /// change to the Library, so typing only filters).
    @State private var catalog: [Indexed] = []
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
    @State private var selection = MediaSelection.shared
    @State private var favourites = MediaFavourites.shared
    @State private var favouritesOnly = false
    @FocusState private var listFocused: Bool

    struct Moment: Identifiable {
        var path: String
        var span: ClosedRange<Double>
        var text: String
        var said: Bool
        /// A favourite range (listed under Favourites).
        var favourite = false
        var id: String { path + "@\(span.lowerBound)-\(span.upperBound)" }
    }

    struct Indexed: Sendable {
        var entry: LibraryStore.Entry
        /// Title, channel, tags and site, lowercased, without accents.
        var words: String
    }

    nonisolated static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// What the search finds: every word typed, in any order.
    private var media: [LibraryStore.Entry] {
        let terms = Self.fold(search).split(whereSeparator: \.isWhitespace).map(String.init)
        let items = favouritesOnly ? catalog.filter { favourites.contains(path: $0.entry.path) } : catalog
        guard !terms.isEmpty else { return items.map(\.entry) }
        return items.filter { item in terms.allSatisfy { item.words.contains($0) } }.map(\.entry)
    }

    /// The favourite ranges (not whole files), shown as moments.
    private var favouriteRanges: [Moment] {
        favourites.all.compactMap { source in
            guard let span = source.span else { return nil }
            let title = catalog.first { $0.entry.path == source.path }?.entry.title ?? URL(fileURLWithPath: source.path).deletingPathExtension().lastPathComponent
            return Moment(path: source.path, span: span, text: title, said: true, favourite: true)
        }
    }

    private func open(_ source: MediaSource) {
        if let onPick {
            onPick([source.span.map { ProjectModel.moment(source.path, $0) } ?? URL(fileURLWithPath: source.path)])
            return
        }
        nav.open(EditorTarget(path: source.path), range: source.span)
    }

    var body: some View {
        VStack(spacing: 0) {
            PaneSearchField(prompt: "Search media", text: $search)
                .overlay(alignment: .trailing) {
                    Button { favouritesOnly.toggle() } label: {
                        Image(systemName: favouritesOnly ? "star.fill" : "star")
                            .foregroundStyle(favouritesOnly ? AnyShapeStyle(Design.Brand.pink) : AnyShapeStyle(.secondary))
                    }
                    .buttonStyle(.plain)
                    .padding(.trailing, 14)
                    .help("Show only favourites")
                }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    // (Its own view: progress ticks redraw it alone, not the whole list.)
                    DownloadingSection()
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
                    if favouritesOnly, !favouriteRanges.isEmpty {
                        SidebarSection(title: Text("Favourites")) {
                            ForEach(favouriteRanges) { momentRow($0) }
                        }
                        .padding(.bottom, 8)
                    }
                    SidebarSection(title: Text("Media")) {
                        ForEach(media) { entry in
                            let source = MediaSource(path: entry.path, span: nil)
                            MediaRow(entry: entry, on: nav.current?.project?.project.origin == entry.path,
                                     selected: selection.source == source, favourite: favourites.contains(path: entry.path))
                                // A click selects; a double-click opens; ⌥-click adds it at the end of a project.
                                .onTapGesture(count: 2) { open(source) }
                                .onTapGesture {
                                    if let project = nav.current?.project, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                                        Task { await project.add([entry.file]) }
                                    } else {
                                        selection.source = source
                                        listFocused = true
                                    }
                                }
                                .onDrag { NSItemProvider(object: entry.file as NSURL) }
                                .contextMenu {
                                    Button("Open") { nav.open(EditorTarget(path: entry.path)) }
                                    if let project = nav.current?.project {
                                        Divider()
                                        Button("Add to the Timeline") { Task { await project.add([entry.file]) } }
                                        if entry.kind == .video {
                                            Button("Add as Overlay") { Task { await project.addOverlay(entry.file) } }
                                                .help("Laid over the picture from the playhead (B-roll, picture in picture)")
                                        }
                                        Button("Add as Sound") { Task { await project.addAudio(entry.file) } }
                                            .help("On a sound track from the playhead (a voice-over, a sound)")
                                    }
                                }
                                .help("Click to select, double-click to open; drag onto a project’s timeline to add it (⌥-click adds it at the end)")
                        }
                    }
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { Color.clear.contentShape(.rect).onTapGesture { selection.source = nil } }
            }
            .focusable()
            .focusEffectDisabled()
            .focused($listFocused)
            .onKeyPress(.return) {
                guard let source = selection.source else { return .ignored }
                open(source)
                return .handled
            }
            .onKeyPress(.escape) {
                guard selection.source != nil else { return .ignored }
                selection.source = nil
                return .handled
            }
            .onKeyPress { press in
                let action = Shortcuts.shared.action(for: press, in: .edit)
                if action == .editFavourite { return favourites.toggleCurrent(in: nav.current?.project) ? .handled : .ignored }
                // Putting the chosen media in, and playing: the open project's, though the list has the focus.
                let assembly: Set<ShortcutAction> = [.editAppend, .editInsert, .editOverwrite, .editPlaceOnTop, .editReplace]
                if let action, assembly.contains(action) || press.key == .space, nav.current?.project != nil {
                    return ProjectView.forward?(press) ?? .ignored
                }
                if press.key == .space, nav.current?.project != nil { return ProjectView.forward?(press) ?? .ignored }
                return .ignored
            }
        }
        .background(.background.secondary)
        .task(id: "\(nav.tabs.count) \(nav.projectsChanged)") {
            projects = ProjectStore.madeProjects()
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
        .task(id: library.entries) {
            // Off the main thread: which files are there, what kind they are, their words.
            let entries = library.entries
            let (found, gone) = await Task.detached(priority: .userInitiated) { () -> ([Indexed], Set<String>) in
                var gone: Set<String> = []
                let items = entries.compactMap { entry -> Indexed? in
                    guard entry.kind == .video || entry.kind == .audio else { return nil }
                    guard FileManager.default.fileExists(atPath: entry.path) else { gone.insert(entry.path); return nil }
                    let words = ([entry.title, entry.uploader, entry.source] + entry.tags.map(Optional.some)).compactMap { $0 }.joined(separator: " ")
                    return Indexed(entry: entry, words: MediaPanel.fold(words))
                }
                return (items.sorted { $0.entry.added > $1.entry.added }, gone)
            }.value
            catalog = found
            missing = gone
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
                    SidebarRow(symbol: entry.2, title: Text(verbatim: entry.1), detail: Text(verbatim: Format.duration(entry.0)),
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
            let hits = await search.search(query, quick: true).prefix(6).filter(\.available)
            let words = query.split(separator: " ").map(String.init)
            let bites = hits.map { ($0.filePath, $0.start, $0.terms + words, $0.text) }
            found += await Task.detached(priority: .userInitiated) {
                bites.map { path, start, terms, text in
                    let bite = MediaPanel.soundbite(path, from: start, terms: terms)
                    return Moment(path: path, span: bite.span, text: bite.text ?? text, said: true)
                }
            }.value
        }
        guard !Task.isCancelled else { return found }
        let indexer = VisualIndexer.shared
        if indexer.indexes.isEmpty { await indexer.reloadInBackground() }
        let indexes = indexer.indexes
        found += await Task.detached(priority: .userInitiated) {
            VisualIndex.search(query, in: indexes, limit: 6).filter { FileManager.default.fileExists(atPath: $0.path) }
                .map { Moment(path: $0.path, span: $0.shot.start...$0.shot.end, text: $0.shot.description, said: false) }
        }.value
        return found
    }

    /// The sentence a hit is in (where its words were found, at most 20 seconds), and its text: a
    /// soundbite.
    nonisolated static func soundbite(_ path: String, from start: Double, terms: [String]) -> (span: ClosedRange<Double>, text: String?) {
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
        let source = MediaSource(path: moment.path, span: moment.span)
        return HStack(alignment: .top, spacing: 8) {
            Image(systemName: moment.favourite ? "star.fill" : moment.said ? "quote.bubble" : "eye")
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
        .background(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(selection.source == source ? AnyShapeStyle(Design.Brand.gradient.opacity(0.28)) : AnyShapeStyle(Color.clear)))
        .contentShape(.rect)
        // A click selects; a double-click opens it there; ⌥-click adds it at the end of a project.
        .onTapGesture(count: 2) { open(source) }
        .onTapGesture {
            if let project = nav.current?.project, NSApp.currentEvent?.modifierFlags.contains(.option) == true {
                Task { await project.add([ProjectModel.moment(moment.path, moment.span)]) }
            } else {
                selection.source = source
                listFocused = true
            }
        }
        .onDrag { NSItemProvider(object: ProjectModel.moment(moment.path, moment.span) as NSURL) }
        .help("Click to select, double-click to open it there; drag onto a project’s timeline to add just this moment (⌥-click adds it at the end)")
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

/// What's downloading, above the media.
private struct DownloadingSection: View {
    @Environment(DownloadManager.self) private var manager

    var body: some View {
        let active = manager.items.filter(\.isActive)
        if !active.isEmpty {
            SidebarSection(title: Text("Downloading")) {
                ForEach(active) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title).font(.callout).lineLimit(2)
                        ProgressView(value: item.progress).controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
            }
            .padding(.bottom, 8)
        }
    }
}

private struct MediaRow: View {
    let entry: LibraryStore.Entry
    /// Open in the tab that is shown.
    let on: Bool
    var selected = false
    var favourite = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            FileThumbnail(file: entry.file, remote: entry.thumbnail, audio: entry.kind == .audio)
                .frame(width: 64, height: 36)
                .clipShape(.rect(cornerRadius: 4))
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title).font(.callout).lineLimit(2)
                if let duration = entry.duration {
                    Text(Format.duration(duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
            if favourite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(Design.Brand.pink).accessibilityLabel("Favourite")
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small, style: .continuous)
            .fill(selected ? AnyShapeStyle(Design.Brand.gradient.opacity(0.28))
                  : on ? AnyShapeStyle(Design.Brand.gradient.opacity(0.14)) : AnyShapeStyle(Color.primary.opacity(hovering ? 0.06 : 0))))
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
            let still = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: request).cgImage
            // Log footage, as the normal picture.
            let path = file.path
            image = await Task.detached { still.map { CameraLog.detect(path)?.apply($0) ?? $0 } }.value.map { NSImage(cgImage: $0, size: .zero) }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Tools

/// The Tools page: every tool as a tile, and the one that's open.
private struct ToolsPage: View {
    @Bindable var nav: StudioNavigator

    var body: some View {
        if let tool = nav.tool {
            toolView(tool)
                // Layout boards 6a–6h: "‹ Tools" on the left of the title bar, no window title.
                .navigationTitle("")
                .toolbar {
                    ToolbarItem(placement: .navigation) {
                        Group {
                            if let back = nav.toolBack {
                                Button(action: back.action) { Label(back.title, systemImage: "chevron.left") }
                                    .help("Back to the folder (Esc)")
                            } else {
                                Button { nav.tool = nil } label: { Label("Tools", systemImage: "chevron.left") }
                                    .help("All tools")
                            }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonStyle(.plain)
                        .font(Design.Studio.body)
                        .foregroundStyle(Design.Studio.text)
                        .padding(.horizontal, 8)
                    }.studioFlat()
                }
        } else {
            // Layout reference, page 6: the tools in groups, and what's running on the right.
            let panel = RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
            HStack(spacing: Design.Studio.panelGap) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 26) {
                        HStack {
                            Text("Tools").font(Design.Studio.pageTitle)
                            Spacer()
                            HStack(spacing: 8) {
                                Image(systemName: "magnifyingglass").font(.system(size: 12)).foregroundStyle(Design.Studio.textQuiet)
                                TextField("Find a tool", text: $find).textFieldStyle(.plain).font(Design.Studio.body)
                            }
                            .padding(.horizontal, 10)
                            .frame(width: 280, height: 30)
                            .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                        }
                        ForEach(Self.groups.indices, id: \.self) { index in
                            let group = Self.groups[index]
                            let shown = group.tools.filter(matches)
                            if !shown.isEmpty {
                                VStack(alignment: .leading, spacing: 12) {
                                    Text(group.title).font(Design.Studio.sectionTitle)
                                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 3), spacing: 8) {
                                        ForEach(shown) { tool in
                                            Button { open(tool) } label: { ToolCard(tool: tool) }
                                                .buttonStyle(.plain)
                                                .help(Text(tool.detail))
                                        }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.horizontal, 32)
                    .padding(.vertical, 28)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Design.Studio.panel, in: panel)
                .clipShape(panel)
                ToolsActivity(recent: recentTools, open: open)
                    .frame(width: 320)
                    .background(Design.Studio.panel, in: panel)
                    .clipShape(panel)
            }
            .navigationTitle("")
        }
    }

    @State private var find = ""
    /// The tools opened last, newest first ("id|seconds since 1970").
    @AppStorage("recentTools") private var recentRaw = ""

    /// The page's groups (Search and the Player are the Library's, so not here).
    static let groups: [(title: LocalizedStringResource, tools: [PluckTool])] = [
        ("Footage", [.derush, .offload, .liveRecorder, .deliveryCheck]),
        ("Motion & Music", [.logoAnimator, .brandPack, .musicFit]),
        ("Delivery & Team", [.officeRender]),
    ]

    private func matches(_ tool: PluckTool) -> Bool {
        let words = find.trimmingCharacters(in: .whitespaces)
        return words.isEmpty || [tool.name, tool.detail, tool.cardName, tool.cardLine]
            .contains { String(localized: $0).localizedCaseInsensitiveContains(words) }
    }

    private var recentTools: [(tool: PluckTool, when: Date)] {
        recentRaw.split(separator: ",").compactMap { item in
            let parts = item.split(separator: "|")
            guard parts.count == 2, let tool = PluckTool(rawValue: String(parts[0])), let seconds = Double(parts[1]) else { return nil }
            return (tool, Date(timeIntervalSince1970: seconds))
        }
    }

    private func open(_ tool: PluckTool) {
        var list = recentTools.filter { $0.tool != tool }
        list.insert((tool, .now), at: 0)
        recentRaw = list.prefix(5).map { "\($0.tool.rawValue)|\(Int($0.when.timeIntervalSince1970))" }.joined(separator: ",")
        nav.open(tool)
    }

    @ViewBuilder private func toolView(_ tool: PluckTool) -> some View {
        switch tool {
        case .derush: DerushView()
        case .offload: OffloadView()
        case .liveRecorder: LiveRecorderView()
        case .deliveryCheck: DeliveryCheckView()
        case .logoAnimator: LogoAnimatorView()
        case .brandPack: BrandPackView()
        case .musicFit: MusicFitView()
        case .officeRender: OfficeRenderView()
        case .library, .findShots, .rawPlayer: EmptyView()
        }
    }
}

/// A tool: its symbol on a raised tile, its name and one line on what it's for (layout reference, page 6).
private struct ToolCard: View {
    let tool: PluckTool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: tool.symbol)
                .font(.system(size: 15))
                .foregroundStyle(Design.Studio.text)
                .frame(width: 40, height: 40)
                .background(hovering ? Design.Studio.line : Design.Studio.raised, in: .rect(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(tool.cardName).font(.system(size: 13)).foregroundStyle(Design.Studio.text).lineLimit(1)
                Text(tool.cardLine).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .frame(height: 76)
        .background(hovering ? Design.Studio.raised : Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.panelRadius, style: .continuous))
        .contentShape(.rect)
        .onHover { hovering = $0 }
    }
}

/// What tools are doing now (offloads copying, a derush), and the tools opened last.
private struct ToolsActivity: View {
    let recent: [(tool: PluckTool, when: Date)]
    let open: (PluckTool) -> Void
    @State private var offload = OffloadCenter.shared
    @State private var derush = DerushView.shared

    private var copying: [OffloadJob] { offload.jobs.filter { offload.states[$0.id] == .copying } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Running").font(Design.Studio.sectionTitle)
                Spacer()
                Text(verbatim: "\(copying.count + (derush.running ? 1 : 0))").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            if copying.isEmpty && !derush.running {
                Text("Nothing running").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            ForEach(copying, id: \.id) { job in
                let live = offload.live[job.id] ?? .init()
                let share = min(Double(live.bytes) / Double(max(job.work, 1)), 1)
                let bytes = { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }
                let left = live.speed > 0 ? Double(job.work - live.bytes) / live.speed : 0
                card(symbol: PluckTool.offload.symbol, title: Text("Offload · \(job.name)"),
                     detail: live.checking ? Text("To \(job.roots.count) drives · checking") : Text("To \(job.roots.count) drives"),
                     share: share,
                     footer: (Text("\(bytes(Int64(share * Double(job.totalBytes)))) of \(bytes(job.totalBytes))"),
                              Text(verbatim: "\(bytes(Int64(live.speed)))/s" + (left > 0 ? " · \(Format.duration(left))" : "")))) { open(.offload) }
            }
            if derush.running {
                let all = derush.clips.count, done = derush.clips.filter { $0.state == .done }.count
                card(symbol: PluckTool.derush.symbol, title: Text("Derush"), detail: Text("Take \(min(done + 1, all)) of \(all)"),
                     share: all == 0 ? 0 : Double(done) / Double(all)) { open(.derush) }
            }
            if !recent.isEmpty {
                Text("Recent").font(Design.Studio.sectionTitle).padding(.top, 8)
                VStack(spacing: 0) {
                    ForEach(recent.prefix(5), id: \.tool) { item in
                        Button { open(item.tool) } label: {
                            HStack(spacing: 10) {
                                Image(systemName: item.tool.symbol).font(.system(size: 13)).foregroundStyle(Design.Studio.text).frame(width: 18)
                                Text(item.tool.cardName).font(Design.Studio.body).foregroundStyle(Design.Studio.text)
                                Spacer()
                                Text(item.when, format: .relative(presentation: .named)).font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
                            }
                            .padding(.horizontal, 6)
                            .frame(height: 40)
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(16)
    }

    private func card(symbol: String, title: Text, detail: Text, share: Double, footer: (Text, Text)? = nil, open: @escaping () -> Void) -> some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: symbol).font(.system(size: 14)).foregroundStyle(Design.Studio.text)
                        .frame(width: 32, height: 32)
                        .background(Design.Studio.raised, in: .rect(cornerRadius: 8, style: .continuous))
                    VStack(alignment: .leading, spacing: 2) {
                        title.font(Design.Studio.body).foregroundStyle(Design.Studio.text).lineLimit(1)
                        detail.font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                    Text(share, format: .percent.precision(.fractionLength(0))).font(Design.Studio.body.monospacedDigit())
                }
                Capsule().fill(Design.Studio.line).frame(height: 3)
                    .overlay(alignment: .leading) {
                        GeometryReader { g in Capsule().fill(Design.Brand.gradient).frame(width: g.size.width * share, height: 3) }
                    }
                if let footer {
                    HStack { footer.0; Spacer(); footer.1 }
                        .font(Design.Studio.hint.monospacedDigit()).foregroundStyle(Design.Studio.textQuiet).lineLimit(1)
                }
            }
            .padding(14)
            .background(Design.Studio.backdrop, in: .rect(cornerRadius: Design.Studio.panelRadius, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

extension PluckTool {
    /// The short name on the Tools page (layout reference, page 6).
    var cardName: LocalizedStringResource {
        switch self {
        case .derush: "Derush"
        case .musicFit: "Fit Music"
        default: name
        }
    }

    /// One line that fits a card; the full sentence is the card's help.
    var cardLine: LocalizedStringResource {
        switch self {
        case .derush: "Sort a shoot into usable takes"
        case .offload: "Copy cards to several drives, checked"
        case .rawPlayer: "Camera raw, timecode and LUTs"
        case .findShots: "Find a moment by word or picture"
        case .liveRecorder: "Record a stream, mark moments"
        case .deliveryCheck: "Look over an export before sending"
        case .logoAnimator: "Animated intro from a logo"
        case .brandPack: "Lower thirds and cards in brand colours"
        case .musicFit: "Make a song as long as the edit"
        case .officeRender: "Render on another Mac"
        case .library: "Everything Pluck saved"
        }
    }
}
