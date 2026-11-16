import QuickLook
import SwiftUI

/// Pluck Library: everything Pluck has saved, in collections (kinds, sites, tags), with search,
/// duplicates, missing files and the space it all takes.
struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var library = LibraryStore.shared
    @State private var collection: Collection? = LibraryView.startCollection ?? .all
    /// The collection to open on (screenshots, a clip opened from Finder).
    @MainActor static var startCollection: Collection?
    private static let showNotification = Notification.Name("PluckLibraryShow")

    #if STUDIO
    /// The Library page, on this collection.
    @MainActor static func show(_ collection: Collection) {
        startCollection = collection
        StudioNavigator.shared.show(.library)
        NotificationCenter.default.post(name: showNotification, object: nil)
    }
    #endif
    @State private var search = ""
    /// The Library split in two: what the right side shows.


    /// A search to start with (Home's field, screenshots): used once, as the Library shows.
    @MainActor static var startSearch = ""
    /// The search field to be typed in as the Library shows (⇧⌘F).
    @MainActor static var focusSearch = false
    static let focusNotification = Notification.Name("PluckLibraryFocusSearch")
    @FocusState private var searchFocused: Bool
    @AppStorage("librarySort") private var sort: Sort = .newest
    /// Only one kind of download shown (nil: all).
    @AppStorage("libraryKind") private var kindFilter = ""
    @State private var tagging: LibraryStore.Entry?
    @State private var newTag = ""
    /// Tagging several at once (the highlighted ones).
    @State private var taggingMany: [LibraryStore.Entry] = []
    @State private var trashing: [LibraryStore.Entry] = []
    @State private var preview: URL?
    @State private var sharing = false
    @Environment(\.openPluckSettings) private var openSettings
    @State private var sending: LibraryStore.Entry?
    @State private var network = NetworkLibraries.shared
    @State private var server = LibraryServer.shared
    /// The highlighted item (its path): Space shows it in Quick Look, arrow keys move it.
    @State private var selected: String?
    /// The item whose name is being typed over (basic never renames, so it stays nil there; the shared key handlers read it).
    @State private var renaming: String?
    #if STUDIO
    @AppStorage("libraryDetailsShown") private var detailsShown = true
    @AppStorage("librarySidebarShown") private var sidebarShown = true
    /// How the collections are shown (folders keep their own, per pane): icons, list or gallery.
    @AppStorage("libraryViewMode") private var libraryMode: FinderViewMode = .icons
    /// Why a rename or duplicate couldn't be done.
    @State private var fileProblem: String?
    @State private var typeSelect = TypeSelect()
    /// Goes up whenever something's opened (a click on a name then doesn't rename it).
    @State private var opens = 0
    @State private var tableOrder = [KeyPathComparator(\LibraryRow.added, order: .reverse)]
    @State private var viewport: CGFloat = 0
    /// A Markdown file read large (Space), instead of Quick Look.
    @State private var reading: URL?
    #endif
    /// The cards' smallest width: Studio's header has a slider for it.
    /// Studio keeps its own size (Basic Pluck's grid is bigger).
    @AppStorage(Edition.isStudio ? "studioLibraryCardSize" : "libraryCardSize") private var cardSize = Edition.isStudio ? 150.0 : 190
    /// Every highlighted item (Shift-click for a run, Command-click for one more), and where a
    /// Shift-click run starts.
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var columns = 1
    @FocusState private var gridFocused: Bool
    /// Checked when the window opens and on refresh, not on every redraw.
    @State private var missing: Set<String> = []
    /// What's shown, worked out once per change (it's read several times a redraw).
    @State private var shownCache = ShownCache()
    @State private var subscriptions = Subscriptions.shared
    @State private var addingSubscription = false

    enum Collection: Hashable {
        case all, videos, audio, photos, recent, duplicates, missing, largest
        case site(String), tag(String)
        /// What a subscription downloaded (its id and name).
        case subscription(UUID, String)
        /// Another Mac's shared Library, by its name.
        case network(String)
        /// Pluck Studio: a folder put in the Library (its id and name), the clips put in one by
        /// one, and a clip opened from Finder (its path). They stay where they are on disk.
        case footage(UUID, String)
        case clips
        case opened(String)
        /// A place on this Mac to browse (a folder of the home folder, a drive), by its path.
        case location(String)

        var title: String {
            switch self {
            case .all: String(localized: "Everything")
            case .videos: String(localized: "Videos")
            case .audio: String(localized: "Music & Audio")
            case .photos: String(localized: "Photos")
            case .recent: String(localized: "Last 7 Days")
            case .duplicates: String(localized: "Duplicates")
            case .missing: String(localized: "Missing Files")
            case .largest: String(localized: "Largest")
            case .site(let name): name
            case .tag(let name): name
            case .subscription(_, let name): name
            case .network(let name): name
            case .footage(_, let name): name
            case .clips: String(localized: "Clips")
            case .opened(let path), .location(let path): FileManager.default.displayName(atPath: path)
            }
        }
    }

    enum Sort: String, CaseIterable, Identifiable {
        case newest, name, size, length
        var id: String { rawValue }
        var label: String {
            switch self {
            case .newest: String(localized: "Newest First")
            case .name: String(localized: "Name")
            case .size: String(localized: "Size")
            case .length: String(localized: "Length")
            }
        }
    }

    /// The places to choose from: footage, downloads, sites, subscriptions, tags.
    private var sidebarList: some View {
        List(selection: sidebarSelection) {
            #if STUDIO
            footageSection
            locationsSection
            AssetLibraryView.librarySidebar
            #endif
            // (Kinds and the order are chosen above the items; tidying up is in the toolbar.)
            Section(Edition.isStudio ? "Downloads" : "Library") {
                Label(String(localized: "Everything"), systemImage: "square.grid.2x2")
                    .badge(count(.all))
                    .tag(Collection.all)
            }
            if !library.sites.isEmpty {
                Section("Sites") {
                    ForEach(library.sites, id: \.self) { row(.site($0), "globe") }
                }
            }
            Section("Subscriptions") {
                ForEach(subscriptions.list) { subscription in
                    Label {
                        Text(subscription.title)
                    } icon: {
                        Image(systemName: subscription.paused ? "pause.circle" : "dot.radiowaves.up.forward")
                    }
                    .badge(count(.subscription(subscription.id, subscription.title)))
                    .tag(Collection.subscription(subscription.id, subscription.title))
                }
                Button {
                    addingSubscription = true
                } label: {
                    Label("Subscribe…", systemImage: "plus")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Follow a channel, playlist or podcast: Pluck downloads what’s new")
            }
            if !library.allTags.isEmpty {
                Section("Tags") {
                    ForEach(library.allTags, id: \.self) { row(.tag($0), "tag") }
                }
            }
            if !network.peers.isEmpty {
                Section("On This Network") {
                    ForEach(network.peers) { peer in
                        Label(peer.name, systemImage: "desktopcomputer").tag(Collection.network(peer.name))
                    }
                }
            }
        }
    }

    /// Studio: three floating panels (places, the grid, the item clicked), as in render 2 of the
    /// 2026-11-12 layout. Basic Pluck: the Mac's split view.
    @ViewBuilder private var layout: some View {
        #if STUDIO
        let panel = RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
        HStack(spacing: Design.Studio.panelGap) {
            if sidebarShown {
                VStack(alignment: .leading, spacing: 0) {
                    sidebarList
                        .listStyle(.sidebar)
                        .scrollContentBackground(.hidden)
                        .labelStyle(QuietIconLabel())
                    // At the sidebar's foot, as in the reference.
                    Button { LibraryView.chooseFootage() } label: {
                        Label("Add folder", systemImage: "plus").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 18)
                    .frame(height: 44)
                    .help("Keep a folder here and make what's in it searchable: nothing is copied")
                }
                .frame(width: 232)
                    .background(Design.Studio.panel, in: panel)
                    .clipShape(panel)
            }
            splitDetail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Design.Studio.panel, in: panel)
                .clipShape(panel)
            if detailsShown, showsGrid, let entry = selected.flatMap({ id in library.entries.first { $0.id == id } }) {
                LibraryDetails(entry: entry, play: { preview = entry.file },
                               addTag: { newTag = ""; tagging = entry; taggingMany = [] }) { menu(for: entry) }
                    .frame(width: 300)
                    .background(Design.Studio.panel, in: panel)
                    .clipShape(panel)
            } else if detailsShown, isFootage, contentScope == nil, let item = footageSelected {
                FinderDetails(item: item, pane: FinderWorkspace.shared.focused)
                    .frame(width: 300)
                    .background(Design.Studio.panel, in: panel)
                    .clipShape(panel)
            }
        }
        #else
        NavigationSplitView {
            sidebarList.navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            primaryDetail
        }
        #endif
    }

    @ToolbarContentBuilder private var toolbarItems: some ToolbarContent {
            #if STUDIO
            // As in the reference: search in the middle; sidebar, details and settings on the right.
            ToolbarItem(placement: .principal) {
                // The last searches offered while it's empty; Escape clears it; Edit ▸ Search (⌘F) types in it.
                StudioSearchField(text: $search, prompt: searchPrompt, key: "⇧⌘F", focused: $searchFocused, suggestions: VisualSearchView.recentSearches)
                    .onExitCommand { search = "" }
            }.studioFlat()
            ToolbarItem {
                Button { sidebarShown.toggle() } label: { Label("Sidebar", systemImage: "sidebar.leading") }
                    .help("Show or hide the sidebar")
            }.studioFlat()
            ToolbarItem {
                Button { detailsShown.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
                    .help("Show or hide the details")
            }.studioFlat()
            ToolbarItem {
                Button { openSettings() } label: { Label("Settings", systemImage: "slider.horizontal.3") }
                    .help("Settings (⌘,)")
            }.studioFlat()
            ToolbarItem {
                if isFootage {
                    ControlGroup {
                        Button { FinderWorkspace.shared.split(.horizontal) } label: {
                            Label("Split Right", systemImage: "square.split.2x1")
                        }
                        .help("Another pane beside this one (⌘\\). ⌥⌘ and the arrows move between panes, ⌥⌘W closes one. Drag between panes to copy, every file checked; hold ⌘ to move.")
                        Button { FinderWorkspace.shared.split(.vertical) } label: {
                            Label("Split Below", systemImage: "square.split.1x2")
                        }
                        .help("Another pane below this one (⇧⌘\\). ⌥⌘T turns a split.")
                    }
                    .disabled(FinderWorkspace.shared.panes.count >= FinderWorkspace.maxPanes)
                }
            }.studioFlat()
            #endif
            #if !STUDIO
            if !isFootage && contentScope == nil {
            ToolbarItem {
                Button {
                    sharing.toggle()
                } label: {
                    Label("Share on This Network", systemImage: server.isRunning ? "dot.radiowaves.left.and.right" : "antenna.radiowaves.left.and.right")
                }
                .foregroundStyle(server.isRunning ? Color.accentColor : Color.primary)
                .help(server.isRunning ? "Shared on this network" : "Share on this network")
                .popover(isPresented: $sharing, arrowEdge: .bottom) { LibrarySharingView() }
            }.studioFlat()
            ToolbarItem {
                Picker("Kind", selection: $kindFilter) {
                    Image(systemName: "square.grid.2x2").help("Everything").tag("")
                    Image(systemName: "film").help("Videos").tag(LibraryStore.Entry.Kind.video.rawValue)
                    Image(systemName: "music.note").help("Music & Audio").tag(LibraryStore.Entry.Kind.audio.rawValue)
                    Image(systemName: "photo").help("Photos").tag(LibraryStore.Entry.Kind.photo.rawValue)
                }
                .pickerStyle(.segmented)
                .help("Show one kind")
            }.studioFlat()
            ToolbarItem {
                Menu {
                    Button("Show Duplicates", systemImage: "square.on.square") { collection = .duplicates }
                    Button("Show Missing Files", systemImage: "questionmark.folder") { collection = .missing }
                    Divider()
                    RemoveMissingCommand()
                } label: {
                    Label("Tidy Up", systemImage: "wand.and.sparkles")
                }
                .help("Tidy up: what's saved twice, and what's no longer there")
            }.studioFlat()
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort")
            }.studioFlat()
            }
            #endif
        }

    var body: some View {
        layout
        #if !STUDIO
        .searchable(text: $search, placement: .toolbar, prompt: searchPrompt)
        .modifier(SearchFocus(focused: $searchFocused))
        #endif
        .onReceive(NotificationCenter.default.publisher(for: Self.focusNotification)) { _ in takeFocus() }
        .toolbar { toolbarItems }
        // Studio: the name is in the grid's header, not the title bar.
        .navigationTitle(Edition.isStudio ? "" : windowTitle)
        .navigationSubtitle(Edition.isStudio || isFootage || contentScope != nil ? "" : summary)
        .frame(minWidth: 760, minHeight: 460)
        .onAppear {
            Self.startCollection = nil
            if !Self.startSearch.isEmpty { search = Self.startSearch; Self.startSearch = "" }
            takeFocus()
            checkFiles()
            network.start()
            // Tests: -PluckScreenshotSelect <n> highlights the first n.
            if ScreenshotMode.scene == "library", case let n = UserDefaults.standard.integer(forKey: "PluckScreenshotSelect"), n > 0 {
                selection = Set(shown.prefix(n).map(\.id))
                selected = shown.first?.id
            }
        }
        .onDisappear { network.stop() }
        .onReceive(NotificationCenter.default.publisher(for: Self.showNotification)) { _ in
            if let start = Self.startCollection { Self.startCollection = nil; collection = start }
        }
        #if STUDIO
        // A folder or drive chosen: opened in the pane in front; the search field narrows it.
        .onChange(of: collection, initial: true) { _, chosen in showInFinder(chosen); filterPanes() }
        .onChange(of: search) { filterPanes() }
        // A drive plugged in or out: a folder on it opens, a drive gone leaves for home.
        .onChange(of: Locations.shared.drives) { _, drives in
            if case .location(let path) = collection, path.hasPrefix("/Volumes/"), !drives.contains(where: { $0.path == path }) {
                collection = .location(FileManager.default.homeDirectoryForCurrentUser.path)
            } else {
                showInFinder(collection)
            }
        }
        #endif
        #if STUDIO
        .background { finderShortcuts }
        .onChange(of: selection) { _, now in
            // (A rubber band or the list changed it: the details follow.)
            if let selected, now.contains(selected) { return }
            selected = now.first
        }
        .sheet(isPresented: Binding(get: { reading != nil }, set: { if !$0 { reading = nil } })) {
            if let reading { MarkdownReader(url: reading) { self.reading = nil } }
        }
        .alert("Can’t Do That", isPresented: Binding(get: { fileProblem != nil }, set: { if !$0 { fileProblem = nil } })) {
            Button("OK") { fileProblem = nil }
        } message: {
            Text(fileProblem ?? "")
        }
        #endif
        .quickLookPreview($preview)
        .sheet(isPresented: $addingSubscription) { SubscribeSheet() }
        .sheet(item: $sending) { entry in
            SendToPhoneView(entry: entry)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { sending = nil } } }
        }
        .alert("Add Tag", isPresented: Binding(get: { tagging != nil }, set: { if !$0 { tagging = nil } })) {
            TextField("Tag", text: $newTag)
            Button("Add") { addTag() }
            Button("Cancel", role: .cancel) { tagging = nil }
        } message: {
            if !library.allTags.isEmpty {
                Text("Your tags: \(library.allTags.formatted(.list(type: .and)))")
            }
        }
        .confirmationDialog(trashing.count == 1 ? String(localized: "Move “\(trashing[0].title)” to the Trash?")
                                : String(localized: "Move \(trashing.count) items to the Trash?"),
                            isPresented: Binding(get: { !trashing.isEmpty }, set: { if !$0 { trashing = [] } })) {
            Button("Move to Trash", role: .destructive) { moveToTrash() }
        } message: {
            Text("You can put it back from the Trash in Finder.")
        }
    }

    /// What the sidebar chose (on the left, when the Library is split).
    @ViewBuilder private var primaryDetail: some View {
        if case .network(let name) = collection, let peer = network.peers.first(where: { $0.name == name }) {
            RemoteLibraryView(peer: peer, search: search)
        } else if let scope = contentScope {
            #if STUDIO
            // Names, and what's said and seen inside: one search.
            VisualSearchView(text: search, scope: scope)
            #endif
        } else if isFootage {
            #if STUDIO
            footageDetail
            #endif
        } else {
            #if STUDIO
            VStack(spacing: 0) {
                libraryHeader
                detail
            }
            #else
            detail
            #endif
        }
    }

    /// The sidebar chooses for the side last clicked when the Library is split (the right side
    /// shows folders and places; anything else goes left).
    private var sidebarSelection: Binding<Collection?> {
        Binding(get: { collection }, set: { chosen in
            #if STUDIO
            // The same place clicked again: back to it (the pane may have gone elsewhere).
            if chosen == collection { showInFinder(chosen); return }
            #endif
            collection = chosen
        })
    }

    #if STUDIO
    /// The plain grid of items (not footage folders, another Mac or a search inside files).
    private var showsGrid: Bool {
        if case .network = collection { return false }
        return !isFootage && contentScope == nil
    }

    /// Over the grid: the collection's name and count, then what to show and in which order.
    private var libraryHeader: some View {
        HStack(spacing: 12) {
            Text(windowTitle).font(Design.Studio.pageTitle).lineLimit(1)
            Text(verbatim: "\(shown.count)").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            Spacer(minLength: 12)
            StudioSegmented(options: Self.collectionModes.map { ($0, $0.title) }, selection: $libraryMode,
                            symbols: Self.collectionModes.map(\.symbol))
            StudioSegmented(options: [("", "All"), (LibraryStore.Entry.Kind.video.rawValue, "Video"),
                                      (LibraryStore.Entry.Kind.audio.rawValue, "Audio"), (LibraryStore.Entry.Kind.photo.rawValue, "Photo")],
                            selection: $kindFilter)
                .help("Show one kind")
            Menu {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                Divider()
                Button("Show Duplicates", systemImage: "square.on.square") { collection = .duplicates }
                Button("Show Missing Files", systemImage: "questionmark.folder") { collection = .missing }
                RemoveMissingCommand()
                Divider()
                Button("Share on This Network…", systemImage: "antenna.radiowaves.left.and.right") { sharing = true }
            } label: {
                StudioMenuLabel(title: sort.label)
            }
            .popover(isPresented: $sharing, arrowEdge: .bottom) { LibrarySharingView() }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Sort, and tidy up: what's saved twice, and what's no longer there")
            HStack(spacing: 6) {
                Image(systemName: "square").font(.system(size: 9))
                StudioSlider(value: $cardSize, range: 110...260).frame(width: 72)
                Image(systemName: "square").font(.system(size: 14))
            }
            .foregroundStyle(Design.Studio.textQuiet)
            .help("Card size")
        }
        .controlSize(.small)
        .padding(.horizontal, Design.Spacing.window)
        .frame(height: 56)
    }

    /// The search field narrows every pane's folder (and none outside the folders).
    private func filterPanes() {
        // (A Library folder searched by what's said and seen shows its own results instead.)
        for pane in FinderWorkspace.shared.panes { pane.filter = isFootage && contentScope == nil ? search : "" }
    }
    #endif

    /// The folder the pane in front is on, or the collection chosen.
    private var windowTitle: String {
        #if STUDIO
        if isFootage, contentScope == nil { return FinderWorkspace.shared.focused.title }
        #endif
        return collection?.title ?? String(localized: "Library")
    }

    /// A folder or a place on disk (what the Player shows), rather than the downloads.
    static func isPlace(_ collection: Collection) -> Bool {
        switch collection {
        case .footage, .clips, .opened, .location: true
        default: false
        }
    }

    /// While searching everything or a Library folder: where the search looks inside clips too
    /// ("all", or the folder's id). Elsewhere (a place browsed, a site, a tag) names only.
    private var contentScope: String? {
        guard Edition.isStudio, !search.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        switch collection ?? .all {
        case .all, .clips: return "all"
        case .footage(let id, _): return id.uuidString
        default: return nil
        }
    }

    private var searchPrompt: LocalizedStringKey {
        switch collection ?? .all {
        case .all, .clips, .footage: Edition.isStudio ? "Search names, what’s said and what’s seen" : "Search titles, channels and tags"
        case .location, .opened: "Search names and text in this folder"
        default: "Search titles, channels and tags"
        }
    }

    private func takeFocus() {
        guard Self.focusSearch else { return }
        Self.focusSearch = false
        DispatchQueue.main.async {
            searchFocused = true
            #if STUDIO
            StudioNavigator.focusTitleBarSearch()
            #endif
        }
    }

    /// A folder or clip on disk is shown (the Player), not Pluck's downloads.
    private var isFootage: Bool { collection.map(Self.isPlace) ?? false }

    private func row(_ collection: Collection, _ symbol: String) -> some View {
        Label(collection.title, systemImage: symbol)
            .badge(count(collection))
            .tag(collection)
    }

    // MARK: - What's shown

    private func entries(in collection: Collection) -> [LibraryStore.Entry] {
        switch collection {
        case .all: library.entries
        case .videos: library.entries.filter { $0.kind == .video }
        case .audio: library.entries.filter { $0.kind == .audio }
        case .photos: library.entries.filter { $0.kind == .photo }
        case .recent: library.entries.filter { $0.added > .now.addingTimeInterval(-7 * 86_400) }
        case .duplicates: library.duplicates
        case .missing: library.entries.filter { missing.contains($0.path) }
        case .largest: Array(library.entries.filter { ($0.size ?? 0) > 0 }.sorted { ($0.size ?? 0) > ($1.size ?? 0) }.prefix(100))
        case .site(let name): library.entries.filter { $0.site == name }
        case .tag(let name): library.entries.filter { $0.tags.contains(name) }
        case .subscription(let id, _): subscriptionEntries(id)
        case .network, .footage, .clips, .opened, .location: []
        }
    }

    private func subscriptionEntries(_ id: UUID) -> [LibraryStore.Entry] {
        guard let subscription = subscriptions.list.first(where: { $0.id == id }) else { return [] }
        let downloaded = Set(subscription.downloaded)
        return library.entries.filter { $0.source.map { downloaded.contains(Links.identity($0)) } ?? false }
    }

    /// The sidebar's numbers, from counts kept by the library (not each row filtering it all).
    private func count(_ collection: Collection) -> Int {
        let counts = library.counts
        switch collection {
        case .all: return library.entries.count
        case .videos: return counts.kinds[.video] ?? 0
        case .audio: return counts.kinds[.audio] ?? 0
        case .photos: return counts.kinds[.photo] ?? 0
        case .recent: return counts.recent
        case .duplicates: return library.duplicates.count
        case .missing: return missing.count
        case .largest: return min(counts.sized, 100)
        case .site(let name): return counts.sites[name] ?? 0
        case .tag(let name): return counts.tags[name] ?? 0
        case .subscription: return entries(in: collection).count
        case .network, .footage, .clips, .opened, .location: return 0
        }
    }

    private var shown: [LibraryStore.Entry] {
        let key = ShownCache.Key(version: library.version, duplicates: library.duplicates.count, missing: missing.count,
                                 collection: collection ?? .all, kind: kindFilter, search: search, sort: sort.rawValue)
        if let list = shownCache.list(for: key) { return list }
        let list = workOutShown()
        shownCache.keep(list, for: key)
        return list
    }

    private func workOutShown() -> [LibraryStore.Entry] {
        let selected = collection ?? .all
        var list = entries(in: selected)
        if let kind = LibraryStore.Entry.Kind(rawValue: kindFilter) { list = list.filter { $0.kind == kind } }
        let query = search.trimmingCharacters(in: .whitespaces)
        if !query.isEmpty {
            list = list.filter { entry in
                entry.title.localizedStandardContains(query) || (entry.uploader?.localizedStandardContains(query) ?? false)
                    || entry.tags.contains { $0.localizedStandardContains(query) }
            }
        }
        // Duplicates and Largest have their own order.
        guard selected != .duplicates, selected != .largest else { return list }
        return switch sort {
        case .newest: list.sorted { $0.added > $1.added }
        case .name: list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        case .size: list.sorted { ($0.size ?? 0) > ($1.size ?? 0) }
        case .length: list.sorted { ($0.duration ?? 0) > ($1.duration ?? 0) }
        }
    }

    private var summary: String {
        let list = shown
        let bytes = list.reduce(Int64(0)) { $0 + ($1.size ?? 0) }
        let size = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
        return String(localized: "\(list.count) items · \(size)")
    }

    @ViewBuilder
    private var detail: some View {
        let list = shown
        if list.isEmpty {
            ToolPage(maxWidth: subscriptionHeader == nil ? 560 : 760) {
                if let subscriptionHeader { subscriptionHeader }
                ToolWelcome(symbol: search.isEmpty ? "books.vertical" : "magnifyingglass",
                            title: Text(emptyTitle), subtitle: Text(emptyDescription))
            }
        } else {
            ScrollViewReader { scroller in
                Group {
                    #if STUDIO
                    switch libraryMode {
                    case .list: libraryTable(list)
                    case .gallery: libraryGallery(list)
                    default: iconGrid(list)
                    }
                    #else
                    iconGrid(list)
                    #endif
                }
                // Like the Finder: click to highlight, Space for Quick Look, arrows to move.
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(.space) { if renaming != nil { return .ignored }; return togglePreview() }
                .onKeyPress(.leftArrow) { if renaming != nil { return .ignored }; return move(by: -1, in: list, scroller) }
                .onKeyPress(.rightArrow) { if renaming != nil { return .ignored }; return move(by: 1, in: list, scroller) }
                .onKeyPress(.upArrow) { if renaming != nil { return .ignored }; return move(by: -rowStep, in: list, scroller) }
                .onKeyPress(.downArrow) { if renaming != nil { return .ignored }; return move(by: rowStep, in: list, scroller) }
                .onKeyPress(.return) { if renaming != nil { return .ignored };
                    guard let entry = list.first(where: { $0.id == selected }) else { return .ignored }
                    #if STUDIO
                    // Return renames, as in Finder (⌘O or a double-click opens).
                    renaming = entry.id
                    #else
                    open(entry)
                    #endif
                    return .handled
                }
                // Delete takes them out of the Library; Command-Delete moves the files to the Trash.
                .onKeyPress(keys: [.delete, .deleteForward]) { press in if renaming != nil { return .ignored };
                    let chosen = list.filter { selection.contains($0.id) }
                    guard !chosen.isEmpty else { return .ignored }
                    if press.modifiers.contains(.command) {
                        let present = chosen.filter { !missing.contains($0.path) }
                        if present.isEmpty { NSSound.beep() } else { trashing = present }
                    } else {
                        removeFromLibrary(chosen)
                    }
                    return .handled
                }
                .onKeyPress(characters: ["a"]) { press in if renaming != nil { return .ignored };
                    guard press.modifiers.contains(.command) else { return .ignored }
                    selection = Set(list.map(\.id))
                    return .handled
                }
                #if STUDIO
                .onKeyPress(characters: ["c"]) { press in if renaming != nil { return .ignored };
                    guard press.modifiers.contains(.command) else { return .ignored }
                    FinderFiles.copyToPasteboard(list.filter { selection.contains($0.id) && !missing.contains($0.path) }.map(\.file))
                    return .handled
                }
                .onKeyPress(.escape) { if renaming != nil { return .ignored };
                    guard !selection.isEmpty else { return .ignored }
                    selection = []
                    selected = nil
                    return .handled
                }
                .onKeyPress(phases: .down) { press in if renaming != nil { return .ignored };
                    guard TypeSelect.isTyping(press), press.key != .space,
                          let index = TypeSelect.match(typeSelect.add(press.characters), in: list.map(\.title)) else { return .ignored }
                    select(list[index])
                    withAnimation(.smooth(duration: 0.2)) { scroller.scrollTo(list[index].id) }
                    return .handled
                }
                #endif
            }
        }
    }

    /// The up and down arrows: a row of cards in the grid, one in a list or the gallery.
    private var rowStep: Int {
        #if STUDIO
        return libraryMode == .icons ? columns : 1
        #else
        return columns
        #endif
    }

    /// The cards (Finder's Icons view).
    private func iconGrid(_ list: [LibraryStore.Entry]) -> some View {
        ScrollView {
            if let subscriptionHeader {
                subscriptionHeader
                    .padding([.horizontal, .top], Design.Spacing.window)
            }
            // Top-aligned: a card with tags or a two-line title doesn't push its picture down.
            LazyVGrid(columns: [GridItem(.adaptive(minimum: cardSize, maximum: cardSize * 1.4), spacing: Edition.isStudio ? 12 : 16, alignment: .top)], spacing: 18) {
                ForEach(list) { entry in
                    card(entry, in: list)
                        .id(entry.id)
                        // One click handler, so highlighting doesn't wait to see if a
                        // double-click follows; the second click of one opens it.
                        .onTapGesture { click(entry, in: list) }
                        .contextMenu { menu(for: entry) }
                }
            }
            .padding(Design.Spacing.window)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                // How many cards fit in a row, the way the adaptive grid lays them out.
                let gap = Edition.isStudio ? 12.0 : 16
                columns = max(1, Int((width - 40 + gap) / (cardSize + gap)))
            }
            #if STUDIO
            // (The whole height: a rubber band can start under the last row.)
            .frame(maxWidth: .infinity, minHeight: viewport, alignment: .top)
            .modifier(RubberBand(selection: $selection))
            #endif
        }
        #if STUDIO
        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { viewport = $0 }
        #endif
    }

    /// A card: in Studio its name can be typed over, and it can be dragged out to Finder or another app.
    @ViewBuilder private func card(_ entry: LibraryStore.Entry, in list: [LibraryStore.Entry]) -> some View {
        #if STUDIO
        LibraryCard(entry: entry, isMissing: missing.contains(entry.path), isSelected: selection.contains(entry.id),
                    nameField: renaming == entry.id ? AnyView(nameField(entry)) : nil,
                    nameTap: { clickName(entry, in: list) })
            .fileDrag { dragged(entry) }
            .rubberBandItem(entry.id)
        #else
        LibraryCard(entry: entry, isMissing: missing.contains(entry.path), isSelected: selection.contains(entry.id))
        #endif
    }

    /// A click (⇧ for a run, ⌘ for one more); the second click of a double-click opens it.
    private func click(_ entry: LibraryStore.Entry, in list: [LibraryStore.Entry]) {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.shift) {
            extend(to: entry, in: list)
        } else if flags.contains(.command) {
            toggle(entry)
        } else {
            select(entry)
            if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { open(entry) }
        }
    }

    /// A subscription's card, at the top of its page.
    private var subscriptionHeader: SubscriptionCard? {
        guard case .subscription(let id, _) = collection, let subscription = subscriptions.list.first(where: { $0.id == id }) else { return nil }
        return SubscriptionCard(subscription: subscription) { collection = .all }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return String(localized: "Nothing Found") }
        return switch collection ?? .all {
        case .subscription: String(localized: "Nothing New Yet")
        case .duplicates: String(localized: "No Duplicates")
        case .missing: String(localized: "No Missing Files")
        default: String(localized: "Nothing Here Yet")
        }
    }

    private var emptyDescription: String {
        if !search.isEmpty { return String(localized: "Try other words.") }
        return switch collection ?? .all {
        case .subscription: String(localized: "New uploads appear here as Pluck downloads them.")
        case .duplicates: String(localized: "Nothing has been saved twice.")
        case .missing: String(localized: "Every file is where Pluck saved it.")
        default: String(localized: "Everything you download or make with Pluck appears here.")
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func menu(for entry: LibraryStore.Entry) -> some View {
        let chosen = selection.contains(entry.id) && selection.count > 1 ? shown.filter { selection.contains($0.id) } : []
        if chosen.count > 1 {
            menu(forMany: chosen)
        } else {
            menu(forOne: entry)
        }
    }

    /// For several highlighted items at once.
    @ViewBuilder
    private func menu(forMany chosen: [LibraryStore.Entry]) -> some View {
        let present = chosen.filter { !missing.contains($0.path) }
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting(present.map(\.file)) }.disabled(present.isEmpty)
        Button("Add Tag…") { newTag = ""; tagging = chosen.first; taggingMany = chosen }
        #if STUDIO
        Button("Copy") { FinderFiles.copyToPasteboard(present.map(\.file)) }.disabled(present.isEmpty)
        Button("Duplicate") { duplicate(present) }.disabled(present.isEmpty)
        #endif
        Divider()
        Button("Remove \(chosen.count) Items from Library") { removeFromLibrary(chosen) }
        Button("Move \(present.count) Items to Trash…", role: .destructive) { trashing = present }.disabled(present.isEmpty)
    }

    @ViewBuilder
    private func menu(forOne entry: LibraryStore.Entry) -> some View {
        let exists = !missing.contains(entry.path)
        Button("Open") { open(entry) }.disabled(!exists)
        if entry.kind == .video || entry.kind == .audio {
            Button("Open in Editor") { EditorTarget(path: entry.path).open(openWindow) }.disabled(!exists)
        }
        #if STUDIO
        if RawFormats.isRawVideo(entry.file) {
            Button("Play") { RawFormats.show(entry.file) }.disabled(!exists)
        }
        #endif
        Button("Quick Look") { selected = entry.id; preview = entry.file }.disabled(!exists)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.file]) }.disabled(!exists)
        Button("Send to Phone…") { sending = entry }.disabled(!exists)
        #if STUDIO
        if Resolve.isInstalled, entry.kind != .other {
            Button("Send to DaVinci") { Resolve.sendAndShow([entry.file]) }.disabled(!exists)
        }
        #endif
        if let source = entry.source, let url = URL(string: source) {
            Button("Open Page in Browser") { NSWorkspace.shared.open(url) }
        }
        #if STUDIO
        Divider()
        Button("Rename") { select(entry); renaming = entry.id }.disabled(!exists)
        Button("Duplicate") { duplicate([entry]) }.disabled(!exists)
        Button("Copy") { FinderFiles.copyToPasteboard([entry.file]) }.disabled(!exists)
        #endif
        Divider()
        Button("Add Tag…") { newTag = ""; tagging = entry; taggingMany = [] }
        if !entry.tags.isEmpty {
            Menu("Remove Tag") {
                ForEach(entry.tags, id: \.self) { tag in
                    Button(tag) { library.setTags(entry.tags.filter { $0 != tag }, for: entry) }
                }
            }
        }
        Divider()
        Button("Remove from Library") { removeFromLibrary([entry]) }
        Button("Move to Trash…", role: .destructive) { trashing = [entry] }.disabled(!exists)
    }

    private func select(_ entry: LibraryStore.Entry) {
        selected = entry.id
        selection = [entry.id]
        anchor = entry.id
        gridFocused = true
        // An open Quick Look follows the selection.
        if preview != nil { preview = missing.contains(entry.path) ? nil : entry.file }
    }

    /// Shift-click: everything from the last plain click to this one.
    private func extend(to entry: LibraryStore.Entry, in list: [LibraryStore.Entry]) {
        guard let anchor, let from = list.firstIndex(where: { $0.id == anchor }),
              let to = list.firstIndex(where: { $0.id == entry.id }) else { return select(entry) }
        selection = Set(list[min(from, to)...max(from, to)].map(\.id))
        selected = entry.id
        gridFocused = true
    }

    /// Command-click: one more, or one less.
    private func toggle(_ entry: LibraryStore.Entry) {
        if selection.contains(entry.id) { selection.remove(entry.id) } else { selection.insert(entry.id) }
        selected = entry.id
        anchor = entry.id
        gridFocused = true
    }

    private func removeFromLibrary(_ entries: [LibraryStore.Entry]) {
        library.remove(entries)
        let gone = Set(entries.map(\.id))
        selection.subtract(gone)
        if let selected, gone.contains(selected) { self.selected = nil }
    }

    private func togglePreview() -> KeyPress.Result {
        guard let path = selected else { return .ignored }
        if preview != nil {
            preview = nil
        } else if missing.contains(path) {
            NSSound.beep()
        } else {
            #if STUDIO
            if FilePreview.isMarkdown(URL(fileURLWithPath: path)) { reading = URL(fileURLWithPath: path); return .handled }
            #endif
            preview = URL(fileURLWithPath: path)
        }
        return .handled
    }

    private func move(by offset: Int, in list: [LibraryStore.Entry], _ scroller: ScrollViewProxy) -> KeyPress.Result {
        guard !list.isEmpty else { return .ignored }
        let current = selected.flatMap { id in list.firstIndex { $0.id == id } }
        let index = current.map { min(max($0 + offset, 0), list.count - 1) } ?? (offset > 0 ? 0 : list.count - 1)
        select(list[index])
        withAnimation(.smooth(duration: 0.2)) { scroller.scrollTo(list[index].id) }
        return .handled
    }

    private func open(_ entry: LibraryStore.Entry) {
        #if STUDIO
        opens += 1
        // Raw clips play in Pluck (most Macs have nothing else that can).
        if RawFormats.isRawVideo(entry.file) { return RawFormats.show(entry.file) }
        #endif
        NSWorkspace.shared.open(entry.file)
    }

    private func addTag() {
        guard let entry = tagging else { return }
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        for one in taggingMany.isEmpty ? [entry] : taggingMany where !tag.isEmpty && !one.tags.contains(tag) {
            library.setTags(one.tags + [tag], for: one)
        }
        tagging = nil
        taggingMany = []
    }

    private func moveToTrash() {
        let entries = trashing
        guard !entries.isEmpty else { return }
        trashing = []
        #if STUDIO
        // (One undo; the Library's entries come back with the files.)
        let failed = FinderFiles.trash(entries.map(\.file)) { moved in
            let trashed = Set(moved.keys.map(\.standardizedFileURL.path))
            removeFromLibrary(entries.filter { trashed.contains($0.file.standardizedFileURL.path) })
        }
        if let failed {
            let alert = NSAlert()
            alert.messageText = failed
            alert.runModal()
        }
        #else
        NSWorkspace.shared.recycle(entries.map(\.file)) { moved, _ in
            Task { @MainActor in
                // Only the ones that went to the Trash leave the Library.
                let trashed = Set(moved.keys.map(\.standardizedFileURL.path))
                removeFromLibrary(entries.filter { trashed.contains($0.file.standardizedFileURL.path) })
            }
        }
        #endif
    }

    private func checkFiles() {
        #if STUDIO
        // Files moved or renamed outside Pluck are followed first; what's left is missing.
        let entries = library.entries
        Task { missing = await LibraryIdentity.check(entries) }
        #else
        let paths = library.entries.map(\.path)
        Task.detached {
            let gone = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            await MainActor.run { missing = gone }
        }
        #endif
    }
}

/// One thing in the library: its picture, title and details.
private struct LibraryCard: View {
    let entry: LibraryStore.Entry
    let isMissing: Bool
    var isSelected = false
    /// Studio: the name being typed over in place, and a click on the name.
    var nameField: AnyView? = nil
    var nameTap: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // A fixed 16:9 frame; the picture fills it and is cropped to it, whatever its own shape.
            Rectangle()
                .fill(.quaternary)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    AsyncImage(url: entry.thumbnail) { phase in
                        if let image = phase.image {
                            image.resizable().scaledToFill()
                        } else {
                            Image(systemName: symbol).font(.largeTitle).foregroundStyle(.tertiary)
                        }
                    }
                }
                .clipShape(.rect(cornerRadius: radius, style: .continuous))
                .overlay {
                    if isSelected {
                        // Studio: a plum outline just outside the picture (brandbook v1).
                        if Edition.isStudio {
                            RoundedRectangle(cornerRadius: radius + 3, style: .continuous).strokeBorder(Design.Brand.gradient, lineWidth: 2).padding(-3)
                        } else {
                            RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3)
                        }
                    }
                }
            .overlay(alignment: .bottomTrailing) {
                if let duration = entry.duration, duration > 0 {
                    Text(Format.duration(duration))
                        .font(.caption2.monospacedDigit().weight(.medium))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .background(.black.opacity(0.65), in: .rect(cornerRadius: Design.Radius.badge))
                        .foregroundStyle(.white)
                        .padding(6)
                }
            }
            .opacity(isMissing ? 0.45 : 1)

            if let nameField { nameField } else { title }
            HStack(spacing: 4) {
                if isMissing, LibraryStore.isOnDisconnectedDrive(entry.path) {
                    // Not gone: its drive isn't connected.
                    Label("Drive not connected", systemImage: "externaldrive.badge.xmark")
                } else if isMissing {
                    Label("Missing", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                } else {
                    Text(details)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
            if !entry.tags.isEmpty, !Edition.isStudio {
                Text(entry.tags.joined(separator: " · "))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Edition.isStudio ? AnyShapeStyle(Design.Studio.textQuiet) : AnyShapeStyle(.tint))
                    .lineLimit(1)
            }
        }
        .padding(6)
        .background(isSelected && !Edition.isStudio ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: Design.Radius.box, style: .continuous))
        .padding(-6)
        .contentShape(.rect)
        .help(entry.path)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder private var title: some View {
        let text = Text(entry.title)
            .font(Edition.isStudio ? Design.Studio.body : .callout.weight(.medium))
            .lineLimit(Edition.isStudio ? 1 : 2)
        if let nameTap { text.onTapGesture(perform: nameTap) } else { text }
    }

    private var radius: CGFloat { Edition.isStudio ? Design.Studio.controlRadius : Design.Radius.thumbnail }

    private var symbol: String {
        switch entry.kind {
        case .video: "film"
        case .audio: "music.note"
        case .photo: "photo"
        case .other: "folder"
        }
    }

    private var details: String {
        // Studio, as in the reference: what it is and how big ("Video · 151 MB").
        if Edition.isStudio {
            let kind = switch entry.kind {
            case .video: String(localized: "Video")
            case .audio: String(localized: "Audio")
            case .photo: String(localized: "Photo")
            case .other: String(localized: "File")
            }
            guard let size = entry.size, size > 0 else { return kind }
            return kind + " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        var parts: [String] = []
        if let site = entry.site { parts.append(site) } else { parts.append(String(localized: "On this Mac")) }
        if let size = entry.size, size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        parts.append(entry.added.formatted(date: .abbreviated, time: .omitted))
        return parts.joined(separator: " · ")
    }
}

#if STUDIO
// MARK: - Folders and clips on disk

extension LibraryView {
    /// Finder's Favorites: Pluck's download folder, the home folder and its own folders, the
    /// folders added here, then the folders (and clips) put in the Library, which Search and Photo
    /// know (they stay where they are). A folder dropped on the section joins Favorites (a clip,
    /// the Library); files dropped on a folder go into it (moved on the same drive, ⌥ copies).
    @ViewBuilder var footageSection: some View {
        let footage = FootageFolders.shared
        Section("Favorites") {
            ForEach(Locations.shared.favorites, id: \.self) { url in
                Label(FileManager.default.displayName(atPath: url.path), systemImage: Locations.shared.symbol(for: url))
                    .tag(Collection.location(url.path))
                    .dropDestination(for: URL.self) { urls, _ in
                        LibraryPanes.shared.drop(urls, into: url)
                        return !urls.isEmpty
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Add to Library") { FootageFolders.shared.add(url) }
                        Divider()
                        Button("Remove from Favorites") { Locations.shared.removeFavorite(url) }
                    }
            }
            ForEach(footage.folderItems) { folder in
                let there = footage.isThere(folder)
                Label(folder.name, systemImage: there ? "folder" : "externaldrive.badge.xmark")
                    .foregroundStyle(there ? .primary : .secondary)
                    .tag(Collection.footage(folder.id, folder.name))
                    .help(there ? String(localized: "\(folder.path) (in the Library: searchable)") : String(localized: "\(folder.path) (its drive isn’t connected)"))
                    .contextMenu { footageMenu(folder) }
            }
            if !footage.clipItems.isEmpty {
                Label("Clips", systemImage: "film.stack")
                    .badge(footage.clipItems.count)
                    .tag(Collection.clips)
            }
            Button { Locations.shared.chooseFavorites() } label: {
                Label("Add Favorite…", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Keep a folder here to browse it: drag one in, or choose it")
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where url.isFileURL {
                let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey, .isPackageKey])).map { $0.isDirectory == true && $0.isPackage != true } ?? false
                if isFolder, !RawFolderScan.isClipFolder(url) { Locations.shared.addFavorite(url) } else { footage.add(url) }
            }
            return !urls.isEmpty
        }
    }

    /// Finder's Locations: the drives plugged in (cards, disks, the network's).
    @ViewBuilder var locationsSection: some View {
        Section("Locations") {
            ForEach(Locations.shared.drives, id: \.self) { url in
                Label(FileManager.default.displayName(atPath: url.path), systemImage: Locations.shared.symbol(for: url))
                    .tag(Collection.location(url.path))
                    .dropDestination(for: URL.self) { urls, _ in
                        LibraryPanes.shared.drop(urls, into: url)
                        return !urls.isEmpty
                    }
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Add to Library") { FootageFolders.shared.add(url) }
                        Button("Offload…") {
                            OffloadView.startSource = url
                            StudioNavigator.shared.open(.offload)
                        }
                        Divider()
                        Button("Eject") { Locations.eject(url) }
                    }
            }
            if !Locations.shared.seesEverything {
                Button {
                    Locations.askForEverything()
                } label: {
                    Label("See Every Folder…", systemImage: "lock.open")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Opens Full Disk Access in System Settings: turn Pluck on there, and macOS stops asking about each folder")
            }
        }
    }

    @ViewBuilder func footageMenu(_ folder: FootageFolders.Folder) -> some View {
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([folder.url]) }
        Divider()
        Button("Remove from Library") { FootageFolders.shared.remove(folder.id) }
    }

    /// Folders and drives: the Library's own Finder, its panes tiled.
    @ViewBuilder var footageDetail: some View {
        if case .footage(let id, _) = collection, let folder = FootageFolders.shared.folders.first(where: { $0.id == id }), !FootageFolders.shared.isThere(folder) {
            ContentUnavailableView("Drive Not Connected", systemImage: "externaldrive.badge.xmark",
                                   description: Text("Connect the drive \(folder.name) is on to play it."))
        } else {
            FinderWorkspaceView()
        }
    }

    /// Copies under way at the foot, and why one couldn't start.
    @ViewBuilder var splitDetail: some View {
        let panes = LibraryPanes.shared
        VStack(spacing: 0) {
            if collection == AssetLibraryView.libraryCollection { AssetLibraryView(librarySearch: search) } else { primaryDetail }
            LibraryTransfers()
        }
        .alert("Can’t Copy", isPresented: Binding(get: { panes.problem != nil }, set: { if !$0 { panes.problem = nil } })) {
            Button("OK") { panes.problem = nil }
        } message: {
            Text(panes.problem ?? "")
        }
    }

    /// What the sidebar chose, in the pane in front.
    func showInFinder(_ collection: Collection?) {
        let pane = FinderWorkspace.shared.focused
        switch collection {
        case .footage(let id, _):
            guard let folder = FootageFolders.shared.folders.first(where: { $0.id == id }), folder.isThere else { return }
            pane.go(to: folder.url, base: folder.url)
        case .clips:
            pane.show(list: String(localized: "Clips"), urls: FootageFolders.shared.clipItems.filter(\.isThere).map(\.url))
        case .location(let path):
            let url = URL(fileURLWithPath: path, isDirectory: true)
            pane.go(to: url, base: url)
        case .opened(let path):
            // A folder opens; a clip plays, its folder behind it.
            let url = URL(fileURLWithPath: path)
            let isFolder = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true && !RawFolderScan.isClipFolder(url)
            if isFolder {
                pane.go(to: url, base: url)
            } else {
                pane.go(to: url.deletingLastPathComponent())
                pane.selection = [url]
                pane.playing = url
            }
        default:
            break
        }
    }

    /// Folders or clips chosen to put in the Library.
    @MainActor static func chooseFootage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = String(localized: "Add")
        panel.message = String(localized: "Pluck plays and searches them where they are. Nothing is copied.")
        guard panel.runModal() == .OK else { return }
        for url in panel.urls { FootageFolders.shared.add(url) }
    }
}

// MARK: - Finder ways for the collections

extension LibraryView {
    /// The views the collections offer (columns are for folders).
    static let collectionModes: [FinderViewMode] = [.icons, .list, .gallery]

    /// ⌘1 to ⌘4 (icons, list, columns, gallery), ⌘O, ⌘D and ⌘I, as in Finder.
    var finderShortcuts: some View {
        ZStack {
            ForEach(Array(FinderViewMode.allCases.enumerated()), id: \.element) { index, mode in
                Button(mode.title) { setMode(mode) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
            }
            Button("Open") { openSelection() }.keyboardShortcut("o")
            Button("Duplicate") { duplicateSelection() }.keyboardShortcut("d")
            Button("Get Info") { detailsShown.toggle() }.keyboardShortcut("i")
            // The Library's file actions (only while it's in front: the Photo page has its own ⌘Z).
            Button("Undo") { fileProblem = FileUndo.key(redo: false) }.keyboardShortcut("z")
            Button("Redo") { fileProblem = FileUndo.key(redo: true) }.keyboardShortcut("z", modifiers: [.command, .shift])
        }
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private func setMode(_ mode: FinderViewMode) {
        if isFootage { FinderWorkspace.shared.focused.mode = mode }
        else if showsGrid, Self.collectionModes.contains(mode) { libraryMode = mode }
        else { NSSound.beep() }
    }

    private var chosenEntries: [LibraryStore.Entry] { shown.filter { selection.contains($0.id) && !missing.contains($0.path) } }

    private func openSelection() {
        if isFootage {
            let pane = FinderWorkspace.shared.focused
            if pane.playing == nil, pane.viewing == nil { pane.openSelection() }
        } else if showsGrid {
            chosenEntries.forEach(open)
        }
    }

    private func duplicateSelection() {
        if isFootage { FinderWorkspace.shared.focused.duplicateSelection() } else if showsGrid { duplicate(chosenEntries) }
    }

    /// The one file selected in the folder in front (for the details panel).
    var footageSelected: FinderItem? {
        let pane = FinderWorkspace.shared.focused
        guard pane.selection.count == 1, pane.playing == nil, pane.viewing == nil else { return nil }
        return pane.items.first { pane.selection.contains($0.url) }
    }

    /// Copies beside them (in the Library too), the copies selected.
    func duplicate(_ entries: [LibraryStore.Entry]) {
        Task {
            var made: Set<String> = []
            for entry in entries {
                do { made.insert(try await FinderFiles.duplicate(entry.file).path) } catch { fileProblem = error.localizedDescription }
            }
            guard !made.isEmpty else { return }
            selection = made
            selected = made.first
        }
    }

    /// The file renamed (its extension kept) and the item's title with it.
    private func rename(_ entry: LibraryStore.Entry, to name: String) {
        renaming = nil
        let name = name.trimmingCharacters(in: .whitespaces)
        guard name != entry.title else { return }
        let ext = entry.file.pathExtension
        do {
            let target = try FinderFiles.rename(entry.file, to: ext.isEmpty ? name : name + "." + ext)
            library.setTitle(name, for: target.path)
            selection = [target.path]
            selected = target.path
            anchor = target.path
        } catch {
            fileProblem = error.localizedDescription
        }
        gridFocused = true
    }

    func nameField(_ entry: LibraryStore.Entry) -> some View {
        InlineNameField(initial: entry.title) { rename(entry, to: $0) } cancel: { renaming = nil; gridFocused = true }
    }

    /// A click on a card's name: the one already selected has its name typed over (unless a
    /// double-click opens it); otherwise a click as anywhere on the card.
    func clickName(_ entry: LibraryStore.Entry, in list: [LibraryStore.Entry]) {
        let plain = (NSApp.currentEvent?.modifierFlags ?? []).isDisjoint(with: [.shift, .command])
        if plain, selection == [entry.id], (NSApp.currentEvent?.clickCount ?? 1) == 1, !missing.contains(entry.path) {
            let before = opens
            Task {
                try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
                if opens == before, selection == [entry.id], renaming == nil { renaming = entry.id }
            }
        }
        click(entry, in: list)
    }

    /// Dragged out: the selection when the card's in it, else the card (files that are there).
    func dragged(_ entry: LibraryStore.Entry) -> [URL] {
        let chosen = selection.contains(entry.id) ? shown.filter { selection.contains($0.id) } : [entry]
        return chosen.filter { !missing.contains($0.path) }.map(\.file)
    }

    /// Finder's List view: sortable, resizable columns.
    func libraryTable(_ list: [LibraryStore.Entry]) -> some View {
        let rows = list.map(LibraryRow.init).sorted(using: tableOrder)
        return Table(rows, selection: $selection, sortOrder: $tableOrder) {
            TableColumn("Name", value: \.name) { row in
                if renaming == row.id { nameField(row.entry) } else {
                    Text(row.name).lineLimit(1).truncationMode(.middle)
                        .opacity(missing.contains(row.entry.path) ? 0.45 : 1)
                        .fileDrag { dragged(row.entry) }
                }
            }
            .width(min: 160, ideal: 320)
            TableColumn("Date Added", value: \.added) { row in
                Text(row.added.formatted(date: .abbreviated, time: .shortened)).foregroundStyle(Design.Studio.textQuiet)
            }
            .width(min: 110, ideal: 150)
            TableColumn("Size", value: \.size) { row in
                Text(row.size > 0 ? ByteCountFormatter.string(fromByteCount: row.size, countStyle: .file) : "—")
                    .foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
            TableColumn("Kind", value: \.kind) { row in Text(row.kind).foregroundStyle(Design.Studio.textQuiet) }
                .width(min: 60, ideal: 80)
            TableColumn("Duration", value: \.duration) { row in
                Text(row.duration > 0 ? Format.duration(row.duration) : "").foregroundStyle(Design.Studio.textQuiet).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first, let entry = list.first(where: { $0.id == id }) { menu(for: entry) }
        } primaryAction: { ids in
            list.filter { ids.contains($0.id) && !missing.contains($0.path) }.forEach(open)
        }
        .scrollContentBackground(.hidden)
        .font(Design.Studio.body)
    }

    /// Finder's Gallery view: the chosen item large, every item in a filmstrip below.
    func libraryGallery(_ list: [LibraryStore.Entry]) -> some View {
        StudioGallery(items: list, current: selected, choose: { click($0, in: list) }, open: open) { entry in
            VStack(spacing: 10) {
                Group {
                    if FilePreview.showsContents(entry.file), !missing.contains(entry.path) {
                        FilePreview(url: entry.file)
                    } else {
                        AsyncImage(url: entry.thumbnail) { phase in
                            if let image = phase.image { image.resizable().scaledToFit() } else {
                                Image(systemName: LibraryRow.symbol(entry)).font(.system(size: 48)).foregroundStyle(Design.Studio.textQuiet)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                if renaming == entry.id { nameField(entry).frame(maxWidth: 360) } else {
                    Text(entry.title).font(Design.Studio.sectionTitle).lineLimit(1)
                }
                Text([LibraryRow.kindName(entry), entry.size.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) }]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Design.Studio.hint).foregroundStyle(Design.Studio.textQuiet)
            }
            .opacity(missing.contains(entry.path) ? 0.45 : 1)
            .contextMenu { menu(for: entry) }
            .fileDrag { dragged(entry) }
        } thumb: { entry in
            AsyncImage(url: entry.thumbnail) { phase in
                if let image = phase.image { image.resizable().scaledToFill() } else {
                    Image(systemName: LibraryRow.symbol(entry)).foregroundStyle(Design.Studio.textQuiet)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Design.Studio.raised)
            .contextMenu { menu(for: entry) }
        }
    }
}

/// A list row's values, for sorting by any column.
struct LibraryRow: Identifiable {
    let entry: LibraryStore.Entry
    var id: String { entry.id }
    var name: String { entry.title }
    var added: Date { entry.added }
    var size: Int64 { entry.size ?? -1 }
    var kind: String { Self.kindName(entry) }
    var duration: Double { entry.duration ?? 0 }

    static func kindName(_ entry: LibraryStore.Entry) -> String {
        switch entry.kind {
        case .video: String(localized: "Video")
        case .audio: String(localized: "Audio")
        case .photo: String(localized: "Photo")
        case .other: String(localized: "File")
        }
    }

    static func symbol(_ entry: LibraryStore.Entry) -> String {
        switch entry.kind {
        case .video: "film"
        case .audio: "music.note"
        case .photo: "photo"
        case .other: "doc"
        }
    }
}
#endif

/// The search field typed in when asked (macOS 15 and later).
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.searchFocused(focused) } else { content }
    }
}

/// The Library's last worked-out list, and what it was worked out for.
@MainActor
final class ShownCache {
    struct Key: Equatable {
        var version: Int, duplicates: Int, missing: Int
        var collection: LibraryView.Collection
        var kind: String, search: String, sort: String
    }

    private var key: Key?
    private var list: [LibraryStore.Entry] = []

    func list(for key: Key) -> [LibraryStore.Entry]? { key == self.key ? list : nil }

    func keep(_ list: [LibraryStore.Entry], for key: Key) {
        self.key = key
        self.list = list
    }
}

#if STUDIO
/// The Library's right panel: the item clicked, its details, and what to do with it.
private struct LibraryDetails<More: View>: View {
    let entry: LibraryStore.Entry
    let play: () -> Void
    let addTag: () -> Void
    @ViewBuilder var more: More

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            if FilePreview.showsContents(entry.file), FileManager.default.fileExists(atPath: entry.path) {
                // A document, text, PDF…: what's in it, to look at before moving or opening it.
                FilePreview(url: entry.file)
                    .frame(minHeight: 300, maxHeight: .infinity)
                    .layoutPriority(1)
                    .background(Design.Studio.raised)
                    .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            } else {
            Rectangle()
                .fill(Design.Studio.raised)
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay {
                    AsyncImage(url: entry.thumbnail) { phase in
                        if let image = phase.image { image.resizable().scaledToFill() }
                    }
                }
                .overlay {
                    Button(action: play) {
                        Image(systemName: "play.fill").font(.system(size: 13)).foregroundStyle(.white)
                            .frame(width: 36, height: 36).background(.black.opacity(0.55), in: .circle)
                    }
                    .buttonStyle(.plain)
                    .help("Quick Look")
                }
                .clipShape(.rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(entry.title).font(Design.Studio.sectionTitle).lineLimit(2)
                Text(verbatim: [entry.uploader ?? entry.site, entry.added.formatted(date: .abbreviated, time: .omitted)]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
            }
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 9) {
                if let duration = entry.duration, duration > 0 { row("Length", Format.duration(duration)) }
                if let size = entry.size, size > 0 { row("Size", ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                row("File", entry.file.pathExtension.uppercased())
                if let site = entry.site { row("From", site) }
            }
            .font(Design.Studio.body)
            HStack(spacing: 6) {
                ForEach(entry.tags, id: \.self) { tag in
                    Text(verbatim: tag).padding(.horizontal, 8).frame(height: 22)
                        .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                }
                Button("+ Tag", action: addTag).buttonStyle(.plain).padding(.horizontal, 6).frame(height: 22)
            }
            .font(Design.Studio.body)
            .foregroundStyle(Design.Studio.textQuiet)
            Spacer(minLength: 0)
            VStack(spacing: 6) {
                if EditorTarget.canOpen(entry.file) {
                    Button { StudioNavigator.shared.open(EditorTarget(path: entry.path)) } label: {
                        Text("Edit").frame(maxWidth: .infinity, minHeight: 32)
                            .foregroundStyle(.white)
                            .background(Design.Brand.deep, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                }
                HStack(spacing: 6) {
                    Button { NSWorkspace.shared.activateFileViewerSelecting([entry.file]) } label: {
                        Text("Show in Finder").frame(maxWidth: .infinity, minHeight: 32)
                            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    Menu { more } label: {
                        Image(systemName: "ellipsis").frame(width: 32, height: 32)
                            .background(Design.Studio.raised, in: .rect(cornerRadius: Design.Studio.controlRadius, style: .continuous))
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("More")
                }
            }
        }
        .padding(Design.Studio.panelInset)
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private func row(_ name: LocalizedStringKey, _ value: String) -> some View {
        GridRow {
            Text(name).foregroundStyle(Design.Studio.textQuiet).frame(width: 72, alignment: .leading)
            Text(verbatim: value).lineLimit(1)
        }
    }
}

/// Sidebar rows with grey icons: plum is kept for what's chosen (brandbook v1).
private struct QuietIconLabel: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        Label { configuration.title } icon: { configuration.icon.foregroundStyle(Design.Studio.textQuiet) }
    }
}
#endif
