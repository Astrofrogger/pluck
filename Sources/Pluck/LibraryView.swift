import QuickLook
import SwiftUI

/// Pluck Library: everything Pluck has saved, in collections (kinds, sites, tags), with search,
/// duplicates, missing files and the space it all takes.
struct LibraryView: View {
    @Environment(\.openWindow) private var openWindow
    @State private var library = LibraryStore.shared
    @State private var collection: Collection? = .all
    @State private var search = ""
    @AppStorage("librarySort") private var sort: Sort = .newest
    @State private var tagging: LibraryStore.Entry?
    @State private var newTag = ""
    @State private var trashing: LibraryStore.Entry?
    @State private var preview: URL?
    @State private var sharing = false
    @State private var sending: LibraryStore.Entry?
    @State private var network = NetworkLibraries.shared
    @State private var server = LibraryServer.shared
    /// The highlighted item (its path): Space shows it in Quick Look, arrow keys move it.
    @State private var selected: String?
    @State private var columns = 1
    @FocusState private var gridFocused: Bool
    /// Checked when the window opens and on refresh, not on every redraw.
    @State private var missing: Set<String> = []

    enum Collection: Hashable {
        case all, videos, audio, photos, recent, duplicates, missing, largest
        case site(String), tag(String)
        /// Another Mac's shared Library, by its name.
        case network(String)

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
            case .network(let name): name
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
            List(selection: $collection) {
                Section("Library") {
                    row(.all, "square.grid.2x2")
                    row(.videos, "film")
                    row(.audio, "music.note")
                    row(.photos, "photo")
                    row(.recent, "clock")
                }
                if !library.sites.isEmpty {
                    Section("Sites") {
                        ForEach(library.sites, id: \.self) { row(.site($0), "globe") }
                    }
                }
                if !library.allTags.isEmpty {
                    Section("Tags") {
                        ForEach(library.allTags, id: \.self) { row(.tag($0), "tag") }
                    }
                }
                Section("Tidy Up") {
                    row(.duplicates, "square.on.square")
                    row(.missing, "questionmark.folder")
                    row(.largest, "externaldrive")
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
            if case .network(let name) = collection, let peer = network.peers.first(where: { $0.name == name }) {
                RemoteLibraryView(peer: peer, search: search)
            } else {
                detail
            }
        }
        .searchable(text: $search, placement: .toolbar, prompt: "Search titles, channels and tags")
        .toolbar {
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
                Picker("Sort", selection: $sort) {
                    ForEach(Sort.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .help("Sort")
            }
        }
        .navigationTitle(collection?.title ?? String(localized: "Library"))
        .navigationSubtitle(summary)
        .frame(minWidth: 760, minHeight: 460)
        .onAppear {
            checkFiles()
            network.start()
        }
        .onDisappear { network.stop() }
        .quickLookPreview($preview)
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
        .confirmationDialog("Move “\(trashing?.title ?? "")” to the Trash?", isPresented: Binding(get: { trashing != nil }, set: { if !$0 { trashing = nil } })) {
            Button("Move to Trash", role: .destructive) { moveToTrash() }
        } message: {
            Text("You can put it back from the Trash in Finder.")
        }
    }

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
        case .network: []
        }
    }

    private func count(_ collection: Collection) -> Int {
        switch collection {
        case .duplicates, .missing, .largest, .all, .videos, .audio, .photos, .recent, .site, .tag: entries(in: collection).count
        case .network: 0
        }
    }

    private var shown: [LibraryStore.Entry] {
        let selected = collection ?? .all
        var list = entries(in: selected)
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
            ContentUnavailableView {
                Label(emptyTitle, systemImage: "books.vertical")
            } description: {
                Text(emptyDescription)
            }
        } else {
            ScrollViewReader { scroller in
                ScrollView {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 190, maximum: 260), spacing: 16)], spacing: 18) {
                        ForEach(list) { entry in
                            LibraryCard(entry: entry, isMissing: missing.contains(entry.path), isSelected: selected == entry.id)
                                .id(entry.id)
                                // One click handler, so highlighting doesn't wait to see if a
                                // double-click follows; the second click of one opens it.
                                .onTapGesture {
                                    select(entry)
                                    if (NSApp.currentEvent?.clickCount ?? 1) >= 2 { open(entry) }
                                }
                                .contextMenu { menu(for: entry) }
                        }
                    }
                    .padding(20)
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
            }
        }
    }

    private var emptyTitle: String {
        if !search.isEmpty { return String(localized: "Nothing Found") }
        return switch collection ?? .all {
        case .duplicates: String(localized: "No Duplicates")
        case .missing: String(localized: "No Missing Files")
        default: String(localized: "Nothing Here Yet")
        }
    }

    private var emptyDescription: String {
        if !search.isEmpty { return String(localized: "Try other words.") }
        return switch collection ?? .all {
        case .duplicates: String(localized: "Nothing has been saved twice.")
        case .missing: String(localized: "Every file is where Pluck saved it.")
        default: String(localized: "Everything you download or make with Pluck appears here.")
        }
    }

    // MARK: - Actions

    @ViewBuilder
    private func menu(for entry: LibraryStore.Entry) -> some View {
        let exists = !missing.contains(entry.path)
        Button("Open") { open(entry) }.disabled(!exists)
        if entry.kind == .video || entry.kind == .audio {
            Button("Open in Pluck Player") {
                openWindow(value: PlayerTarget(filePath: entry.path, transcriptID: entry.transcriptID, start: nil, tab: nil))
            }
            .disabled(!exists)
        }
        Button("Quick Look") { selected = entry.id; preview = entry.file }.disabled(!exists)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([entry.file]) }.disabled(!exists)
        Button("Send to Phone…") { sending = entry }.disabled(!exists)
        if Resolve.isInstalled, entry.kind != .other {
            Button("Send to DaVinci Resolve") { Resolve.sendAndShow([entry.file]) }.disabled(!exists)
        }
        if let source = entry.source, let url = URL(string: source) {
            Button("Open Page in Browser") { NSWorkspace.shared.open(url) }
        }
        Divider()
        Button("Add Tag…") { newTag = ""; tagging = entry }
        if !entry.tags.isEmpty {
            Menu("Remove Tag") {
                ForEach(entry.tags, id: \.self) { tag in
                    Button(tag) { library.setTags(entry.tags.filter { $0 != tag }, for: entry) }
                }
            }
        }
        Divider()
        Button("Remove from Library") { library.remove([entry]) }
        Button("Move to Trash…", role: .destructive) { trashing = entry }.disabled(!exists)
    }

    private func select(_ entry: LibraryStore.Entry) {
        selected = entry.id
        gridFocused = true
        // An open Quick Look follows the selection.
        if preview != nil { preview = missing.contains(entry.path) ? nil : entry.file }
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
        NSWorkspace.shared.open(entry.file)
    }

    private func addTag() {
        guard let entry = tagging else { return }
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tag.isEmpty, !entry.tags.contains(tag) { library.setTags(entry.tags + [tag], for: entry) }
        tagging = nil
    }

    private func moveToTrash() {
        guard let entry = trashing else { return }
        trashing = nil
        NSWorkspace.shared.recycle([entry.file]) { _, error in
            Task { @MainActor in
                if error == nil { library.remove([entry]) }
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
                if isMissing {
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
