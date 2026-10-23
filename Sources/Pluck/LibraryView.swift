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
    @State private var search = LibraryView.startSearch
    /// The Library split in two: what the right side shows.


    /// A search to start with (screenshots).
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
    @State private var sending: LibraryStore.Entry?
    @State private var network = NetworkLibraries.shared
    @State private var server = LibraryServer.shared
    /// The highlighted item (its path): Space shows it in Quick Look, arrow keys move it.
    @State private var selected: String?
    /// Every highlighted item (Shift-click for a run, Command-click for one more), and where a
    /// Shift-click run starts.
    @State private var selection: Set<String> = []
    @State private var anchor: String?
    @State private var columns = 1
    @FocusState private var gridFocused: Bool
    /// Checked when the window opens and on refresh, not on every redraw.
    @State private var missing: Set<String> = []
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

    var body: some View {
        NavigationSplitView {
            List(selection: sidebarSelection) {
                #if STUDIO
                footageSection
                locationsSection
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
            .navigationSplitViewColumnWidth(min: 180, ideal: 210)
        } detail: {
            #if STUDIO
            splitDetail
            #else
            primaryDetail
            #endif
        }
        .searchable(text: $search, placement: .toolbar, prompt: searchPrompt)
        .modifier(SearchFocus(focused: $searchFocused))
        .onReceive(NotificationCenter.default.publisher(for: Self.focusNotification)) { _ in takeFocus() }
        #if STUDIO
        // The last searches, to run again.
        .searchSuggestions {
            if search.isEmpty {
                ForEach(VisualSearchView.recentSearches, id: \.self) { recent in
                    Label(recent, systemImage: "clock.arrow.circlepath").searchCompletion(recent)
                }
            }
        }
        #endif
        .toolbar {
            #if STUDIO
            ToolbarItem {
                if isFootage {
                    Button { FinderWorkspace.shared.split(.horizontal) } label: {
                        Label("Split", systemImage: "rectangle.split.2x1")
                    }
                    .disabled(FinderWorkspace.shared.panes.count >= FinderWorkspace.maxPanes)
                    .help("Another pane beside this one (⌘\\, ⇧⌘\\ below). ⌥⌘ and the arrows move between panes, ⇧⌥⌘ and the arrows swap them, ⌥⌘W closes one. Drag between panes to copy, every file checked.")
                }
            }
            #endif
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
            }
            ToolbarItem {
                Picker("Kind", selection: $kindFilter) {
                    Image(systemName: "square.grid.2x2").help("Everything").tag("")
                    Image(systemName: "film").help("Videos").tag(LibraryStore.Entry.Kind.video.rawValue)
                    Image(systemName: "music.note").help("Music & Audio").tag(LibraryStore.Entry.Kind.audio.rawValue)
                    Image(systemName: "photo").help("Photos").tag(LibraryStore.Entry.Kind.photo.rawValue)
                }
                .pickerStyle(.segmented)
                .help("Show one kind")
            }
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
            }
            ToolbarItem {
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort")
            }
            }
        }
        .navigationTitle(windowTitle)
        .navigationSubtitle(isFootage || contentScope != nil ? "" : summary)
        .frame(minWidth: 760, minHeight: 460)
        .onAppear {
            Self.startCollection = nil
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
            detail
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
    /// The search field narrows every pane's folder (and none outside the folders).
    private func filterPanes() {
        for pane in FinderWorkspace.shared.panes { pane.filter = isFootage ? search : "" }
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
        case .location, .opened: "Search clips"
        default: "Search titles, channels and tags"
        }
    }

    private func takeFocus() {
        guard Self.focusSearch else { return }
        Self.focusSearch = false
        DispatchQueue.main.async { searchFocused = true }
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

    private func count(_ collection: Collection) -> Int {
        switch collection {
        case .duplicates, .missing, .largest, .all, .videos, .audio, .photos, .recent, .site, .tag, .subscription: entries(in: collection).count
        case .network, .footage, .clips, .opened, .location: 0
        }
    }

    private var shown: [LibraryStore.Entry] {
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
                ScrollView {
                    if let subscriptionHeader {
                        subscriptionHeader
                            .padding([.horizontal, .top], Design.Spacing.window)
                    }
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], spacing: 18) {
                        ForEach(list) { entry in
                            LibraryCard(entry: entry, isMissing: missing.contains(entry.path), isSelected: selection.contains(entry.id))
                                .id(entry.id)
                                // One click handler, so highlighting doesn't wait to see if a
                                // double-click follows; the second click of one opens it.
                                .onTapGesture {
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
                                .contextMenu { menu(for: entry) }
                        }
                    }
                    .padding(Design.Spacing.window)
                    .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width in
                        // How many cards fit in a row, the way the adaptive grid lays them out.
                        columns = max(1, Int((width - 40 + 16) / (190 + 16)))
                    }
                }
                // Like the Finder: click to highlight, Space for Quick Look, arrows to move.
                .focusable()
                .focused($gridFocused)
                .focusEffectDisabled()
                .onKeyPress(.space) { togglePreview() }
                .onKeyPress(.leftArrow) { move(by: -1, in: list, scroller) }
                .onKeyPress(.rightArrow) { move(by: 1, in: list, scroller) }
                .onKeyPress(.upArrow) { move(by: -columns, in: list, scroller) }
                .onKeyPress(.downArrow) { move(by: columns, in: list, scroller) }
                .onKeyPress(.return) {
                    guard let entry = list.first(where: { $0.id == selected }) else { return .ignored }
                    open(entry)
                    return .handled
                }
                // Delete takes them out of the Library; Command-Delete moves the files to the Trash.
                .onKeyPress(keys: [.delete, .deleteForward]) { press in
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
                .onKeyPress(characters: ["a"]) { press in
                    guard press.modifiers.contains(.command) else { return .ignored }
                    selection = Set(list.map(\.id))
                    return .handled
                }
            }
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
        NSWorkspace.shared.recycle(entries.map(\.file)) { moved, _ in
            Task { @MainActor in
                // Only the ones that went to the Trash leave the Library.
                let trashed = Set(moved.keys.map(\.standardizedFileURL.path))
                removeFromLibrary(entries.filter { trashed.contains($0.file.standardizedFileURL.path) })
            }
        }
    }

    private func checkFiles() {
        let paths = library.entries.map(\.path)
        Task.detached {
            let gone = Set(paths.filter { !FileManager.default.fileExists(atPath: $0) })
            await MainActor.run { missing = gone }
        }
    }
}

/// One thing in the library: its picture, title and details.
private struct LibraryCard: View {
    let entry: LibraryStore.Entry
    let isMissing: Bool
    var isSelected = false

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
                .clipShape(.rect(cornerRadius: Design.Radius.thumbnail, style: .continuous))
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Design.Radius.thumbnail, style: .continuous).strokeBorder(Color.accentColor, lineWidth: 3)
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

            Text(entry.title)
                .font(.callout.weight(.medium))
                .lineLimit(2)
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
            if !entry.tags.isEmpty {
                Text(entry.tags.joined(separator: " · "))
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.tint)
                    .lineLimit(1)
            }
        }
        .padding(6)
        .background(isSelected ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.clear), in: .rect(cornerRadius: Design.Radius.box, style: .continuous))
        .padding(-6)
        .contentShape(.rect)
        .help(entry.path)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var symbol: String {
        switch entry.kind {
        case .video: "film"
        case .audio: "music.note"
        case .photo: "photo"
        case .other: "folder"
        }
    }

    private var details: String {
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
    /// Finder's Favorites: the home folder and its own folders, then the folders (and clips) put
    /// in the Library, which Search and Photo know (they stay where they are). A folder dropped
    /// here is put in.
    @ViewBuilder var footageSection: some View {
        let footage = FootageFolders.shared
        Section("Favorites") {
            ForEach(Locations.shared.favorites, id: \.self) { url in
                Label(FileManager.default.displayName(atPath: url.path), systemImage: Locations.symbol(url))
                    .tag(Collection.location(url.path))
                    .contextMenu {
                        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
                        Button("Add to Library") { FootageFolders.shared.add(url) }
                    }
            }
            ForEach(footage.folderItems) { folder in
                Label(folder.name, systemImage: folder.isThere ? "folder" : "externaldrive.badge.xmark")
                    .foregroundStyle(folder.isThere ? .primary : .secondary)
                    .tag(Collection.footage(folder.id, folder.name))
                    .help(folder.isThere ? String(localized: "\(folder.path) (in the Library: searchable)") : String(localized: "\(folder.path) (its drive isn’t connected)"))
                    .contextMenu { footageMenu(folder) }
            }
            if !footage.clipItems.isEmpty {
                Label("Clips", systemImage: "film.stack")
                    .badge(footage.clipItems.count)
                    .tag(Collection.clips)
            }
            Button {
                LibraryView.chooseFootage()
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Keep a folder here and make what's in it searchable: nothing is copied")
        }
        .dropDestination(for: URL.self) { urls, _ in
            for url in urls where url.isFileURL { footage.add(url) }
            return !urls.isEmpty
        }
    }

    /// Finder's Locations: the drives plugged in (cards, disks, the network's).
    @ViewBuilder var locationsSection: some View {
        Section("Locations") {
            ForEach(Locations.shared.drives, id: \.self) { url in
                Label(FileManager.default.displayName(atPath: url.path), systemImage: Locations.symbol(url))
                    .tag(Collection.location(url.path))
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
        if case .footage(let id, _) = collection, let folder = FootageFolders.shared.folders.first(where: { $0.id == id }), !folder.isThere {
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
            primaryDetail
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
#endif

/// The search field typed in when asked (macOS 15 and later).
private struct SearchFocus: ViewModifier {
    var focused: FocusState<Bool>.Binding

    func body(content: Content) -> some View {
        if #available(macOS 15, *) { content.searchFocused(focused) } else { content }
    }
}
