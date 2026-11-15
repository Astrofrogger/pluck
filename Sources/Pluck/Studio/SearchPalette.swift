import SwiftUI

/// Edit ▸ Search (⌘F): one search over the window, like Spotlight. It looks where the page shown
/// looks (or everywhere): library items, what's said and seen in them, projects, photos, the Photo
/// page's tools, Pluck's tools and the pages. The page's own title-bar fields stay as they are:
/// they filter what the page shows (Home's takes a link), which this doesn't replace.
@MainActor
@Observable
final class SearchPalette {
    static let shared = SearchPalette()

    enum Scope: Hashable { case page, everywhere }

    /// Kinds of result, in the order their groups show.
    enum Kind: Int, CaseIterable {
        case recent, page, tool, photoTool, project, review, library, said, seen, file, photo

        var title: LocalizedStringKey {
            switch self {
            case .recent: "Recent"
            case .page: "Pages"
            case .tool: "Tools"
            case .photoTool: "Photo Tools"
            case .project: "Projects"
            case .review: "Review Projects"
            case .library: "Library"
            case .said: "What’s Said"
            case .seen: "What’s Seen"
            case .file: "Files"
            case .photo: "Photos"
            }
        }
    }

    struct Item: Identifiable {
        let id: String
        let kind: Kind
        let title: String
        var detail = ""
        var symbol = "magnifyingglass"
        /// The file it is (⌘Return shows it in Finder; its thumbnail is shown).
        var file: URL?
        /// A picture made of it already (a shot, a project's frame).
        var picture: URL?
        var audio = false
        let open: @MainActor () -> Void
    }

    private(set) var shown = false
    var query = "" { didSet { if query != oldValue { refresh() } } }
    var scope = Scope.page { didSet { if scope != oldValue { refresh() } } }
    private(set) var items: [Item] = []
    var selected = 0
    /// The page it was opened over: what "This page" means.
    private(set) var page: StudioNavigator.Page = .home
    /// Goes up each time it's asked for (the field takes the typing again).
    private(set) var opened = 0
    /// Goes up each time a search has finished (for the self-test).
    private(set) var finished = 0
    @ObservationIgnored private var projects: [Project] = []
    @ObservationIgnored private var work: Task<Void, Never>?

    nonisolated private static let perGroup = 6
    private static let recentKey = "recentSearches"

    /// The kinds looked for: everything, the same on every page (owner, 2026-11-15).
    var kinds: Set<Kind> { Set(Kind.allCases) }

    /// No scope switch: the popup is the same on every page.
    var hasScope: Bool { false }

    func show() {
        opened += 1
        guard !shown else { return }
        page = StudioNavigator.shared.page
        shown = true
        scope = .page
        query = ""
        refresh()
        Task {
            projects = await Task.detached(priority: .userInitiated) { ProjectStore.madeProjects() }.value
            refresh()
        }
    }

    func close() {
        work?.cancel()
        shown = false
        items = []
    }

    func move(_ by: Int) {
        guard !items.isEmpty else { return }
        selected = min(max(selected + by, 0), items.count - 1)
    }

    /// Opens the chosen result (a recent search is searched again); `reveal`: shows its file in Finder.
    func choose(_ index: Int? = nil, reveal: Bool = false) {
        let index = index ?? selected
        guard items.indices.contains(index) else { return }
        let item = items[index]
        if item.kind == .recent { query = item.title; return }
        if reveal {
            guard let file = item.file else { NSSound.beep(); return }
            remember(query)
            close()
            NSWorkspace.shared.activateFileViewerSelecting([file])
            return
        }
        remember(query)
        close()
        item.open()
    }

    // MARK: - Searching

    private func refresh() {
        work?.cancel()
        guard shown else { return }
        let text = query.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else {
            items = recents
            selected = 0
            finished += 1
            return
        }
        let kinds = kinds
        work = Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            var found = quick(text, kinds)
            set(found)
            found += await slow(text, kinds)
            guard !Task.isCancelled else { return }
            set(found)
            finished += 1
        }
    }

    /// Grouped by kind; the one chosen stays chosen as more come in.
    private func set(_ list: [Item]) {
        let kept = items.indices.contains(selected) ? items[selected].id : nil
        items = list.enumerated().sorted { ($0.element.kind.rawValue, $0.offset) < ($1.element.kind.rawValue, $1.offset) }.map(\.element)
        selected = items.firstIndex { $0.id == kept } ?? 0
    }

    private var recents: [Item] {
        guard kinds.contains(.recent) else { return [] }
        return (UserDefaults.standard.string(forKey: Self.recentKey) ?? "").split(separator: "\n").prefix(5).map { text in
            Item(id: "recent:" + text, kind: .recent, title: String(text), symbol: "clock.arrow.circlepath") {}
        }
    }

    /// Kept with the Library's recent searches (one list, newest first).
    private func remember(_ text: String) {
        let text = text.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        let old = (UserDefaults.standard.string(forKey: Self.recentKey) ?? "").split(separator: "\n").map(String.init)
        let list = [text] + old.filter { $0.caseInsensitiveCompare(text) != .orderedSame }
        UserDefaults.standard.set(list.prefix(8).joined(separator: "\n"), forKey: Self.recentKey)
    }

    /// Every word typed is in it.
    nonisolated private static func has(_ words: [String], _ texts: String...) -> Bool {
        words.allSatisfy { word in texts.contains { $0.localizedStandardContains(word) } }
    }

    /// What's known already: pages, tools, projects and the library.
    private func quick(_ text: String, _ kinds: Set<Kind>) -> [Item] {
        let words = text.split(separator: " ").map(String.init)
        let nav = StudioNavigator.shared
        var found: [Item] = []
        if kinds.contains(.page) {
            found += StudioNavigator.Page.allCases.filter { Self.has(words, $0.name) }.map { page in
                Item(id: "page:" + page.rawValue, kind: .page, title: page.name, symbol: page.symbol) { nav.show(page) }
            }
        }
        if kinds.contains(.tool) {
            found += PluckTool.allCases.filter { Self.has(words, String(localized: $0.name) + " " + String(localized: $0.detail)) }
                .prefix(Self.perGroup).map { tool in
                    Item(id: "tool:" + tool.rawValue, kind: .tool, title: String(localized: tool.name), detail: String(localized: tool.detail),
                         symbol: tool.symbol) { nav.open(tool) }
                }
        }
        if kinds.contains(.photoTool) {
            // As the Adjust panel's own search: a section shows on its own, a tool elsewhere opens.
            let sections = AdjustSection.allCases.filter { $0.words.contains { $0.localizedCaseInsensitiveContains(text) } }.map { section in
                Item(id: "section:" + section.rawValue, kind: .photoTool, title: section.words[0], symbol: "slider.horizontal.3") {
                    UserDefaults.standard.set(PhotoInspector.Tab.adjust.rawValue, forKey: "photoInspectorTab")
                    PhotoEditing.shared.toolQuery = section.words[0]
                    PhotoEditing.shared.findingTool = true
                    nav.show(.photo)
                }
            }
            let jumps = ToolJump.allCases.filter { $0.matches(text) }.map { jump in
                Item(id: "jump:\(jump)", kind: .photoTool, title: jump.title, symbol: jump.symbol) {
                    PhotoEditing.shared.jump = jump
                    nav.show(.photo)
                }
            }
            found += (jumps + sections).prefix(Self.perGroup)
        }
        if kinds.contains(.project) {
            found += projects.filter { Self.has(words, $0.name) }.prefix(Self.perGroup).map { project in
                Item(id: "project:" + project.id.uuidString, kind: .project, title: project.name,
                     detail: project.modified.formatted(.relative(presentation: .named)), symbol: "film",
                     file: ProjectStore.url(for: project.id), picture: ProjectStore.thumbnail(for: project.id)) { nav.open(project) }
            }
        }
        if kinds.contains(.review) {
            found += DeliverStore.shared.projects.filter { Self.has(words, $0.name) }.prefix(Self.perGroup).map { project in
                Item(id: "review:" + project.id.uuidString, kind: .review, title: project.name, symbol: "paperplane") {
                    nav.deliver = .project(project.id, folder: nil)
                    nav.show(.deliver)
                }
            }
        }
        if kinds.contains(.library) {
            found += LibraryStore.shared.entries.lazy
                .filter { entry in Self.has(words, entry.title + " " + (entry.uploader ?? "") + " " + entry.tags.joined(separator: " ")) }
                .prefix(Self.perGroup).map { entry in
                    Item(id: "library:" + entry.path, kind: .library, title: entry.title, detail: entry.uploader ?? "",
                         symbol: entry.kind == .audio ? "music.note" : entry.kind == .photo ? "photo" : "film",
                         file: entry.file, picture: entry.thumbnail, audio: entry.kind == .audio) { Self.open(entry.file) }
                }
        }
        return found
    }

    /// What takes a moment: inside the clips, the watched folders and the photos.
    private func slow(_ text: String, _ kinds: Set<Kind>) async -> [Item] {
        let nav = StudioNavigator.shared
        var found: [Item] = []
        if kinds.contains(.said), let search = AppDelegate.shared?.ai.search {
            found += await search.search(text, quick: true).filter(\.available).prefix(Self.perGroup).map { hit in
                Item(id: "said:" + hit.id, kind: .said, title: hit.title, detail: hit.text, symbol: "waveform",
                     file: URL(fileURLWithPath: hit.filePath)) { nav.open(EditorTarget(path: hit.filePath), at: hit.start) }
            }
        }
        if kinds.contains(.seen) {
            let indexes = VisualIndexer.shared.indexes
            let hits = await Task.detached(priority: .userInitiated) { VisualIndex.search(text, in: indexes, limit: Self.perGroup) }.value
            found += hits.map { hit in
                Item(id: "seen:" + hit.id, kind: .seen, title: URL(fileURLWithPath: hit.path).deletingPathExtension().lastPathComponent,
                     detail: hit.shot.description, symbol: "eye", file: URL(fileURLWithPath: hit.path),
                     picture: VisualIndex.thumbnailURL(path: hit.path, start: hit.shot.start)) {
                    nav.open(EditorTarget(path: hit.path), at: hit.shot.start)
                }
            }
        }
        if kinds.contains(.file) {
            // Footage in the watched folders (the library's own are above; photos are Photos when those show).
            let library = Set(LibraryStore.shared.entries.map(\.path))
            let paths = FootageFolders.shared.allVideos + (kinds.contains(.photo) ? [] : FootageFolders.shared.allPhotos)
            let words = text.split(separator: " ").map(String.init)
            let hits = await Task.detached(priority: .userInitiated) {
                Array(paths.lazy.filter { !library.contains($0) && Self.has(words, ($0 as NSString).lastPathComponent) }.prefix(Self.perGroup))
            }.value
            found += hits.map { path in
                let url = URL(fileURLWithPath: path)
                return Item(id: "file:" + path, kind: .file, title: url.deletingPathExtension().lastPathComponent,
                            detail: (url.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath, symbol: "film", file: url) {
                    EditorTarget.canOpen(url) ? nav.open(EditorTarget(path: path)) : Self.showPhoto(path)
                }
            }
        }
        if kinds.contains(.photo) {
            // By name, keywords, tags and the text in it, as the Photo page's Find.
            let words = PhotoSearch.words(text)
            var keys: [String] = []
            for key in PhotoCatalog.shared.allPhotos where PhotoSearch.matches(words, PhotoSearch.words(of: key)) {
                keys.append(key)
                if keys.count == Self.perGroup { break }
                await Task.yield()
                if Task.isCancelled { return found }
            }
            found += keys.map { key in
                let file = URL(fileURLWithPath: PhotoCatalog.file(of: key))
                return Item(id: "photo:" + key, kind: .photo, title: PhotoCatalog.displayName(key),
                            detail: (file.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath,
                            symbol: "photo", file: file) { Self.showPhoto(key) }
            }
        }
        return found
    }

    /// A video or song on the Edit page; a raw clip in the Player; anything else in its own app (as the Library opens it).
    private static func open(_ file: URL) {
        if RawFormats.isRawVideo(file) { return RawFormats.show(file) }
        if EditorTarget.canOpen(file) { return StudioNavigator.shared.open(EditorTarget(path: file.path)) }
        if PhotoCatalog.shared.allPhotos.contains(file.path) { return showPhoto(file.path) }
        NSWorkspace.shared.open(file)
    }

    private static func showPhoto(_ key: String) {
        PhotoEditing.shared.reveal = key
        StudioNavigator.shared.show(.photo)
    }
}

extension StudioNavigator.Page {
    /// The page's name, as text.
    var name: String {
        switch self {
        case .home: String(localized: "Home")
        case .library: String(localized: "Library")
        case .edit: String(localized: "Edit")
        case .photo: String(localized: "Photo")
        case .deliver: String(localized: "Deliver")
        case .tools: String(localized: "Tools")
        }
    }
}

// MARK: - The panel

/// The search floating over the page, near the top, the page dimmed behind it.
struct SearchPaletteView: View {
    @State private var palette = SearchPalette.shared
    @FocusState private var focused: Bool

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.5)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { palette.close() }
            panel
                .frame(width: 620)
                .padding(.top, 64)
        }
        .onAppear { DispatchQueue.main.async { focused = true } }
        .onChange(of: palette.opened) { focused = true }
    }

    private var panel: some View {
        let shape = RoundedRectangle(cornerRadius: Design.Studio.panelRadius, style: .continuous)
        return VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").font(.system(size: 15)).foregroundStyle(Design.Studio.textQuiet)
                TextField("Search", text: $palette.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 17))
                    .foregroundStyle(Design.Studio.text)
                    .focused($focused)
                    .onSubmit { palette.choose() }
                    .onExitCommand { palette.close() }
                    .onKeyPress(.upArrow) { palette.move(-1); return .handled }
                    .onKeyPress(.downArrow) { palette.move(1); return .handled }
                    .onKeyPress(keys: [.return]) { press in
                        guard press.modifiers.contains(.command) else { return .ignored }
                        palette.choose(reveal: true)
                        return .handled
                    }
                if palette.hasScope {
                    StudioSegmented(options: [(SearchPalette.Scope.page, palette.page.title), (.everywhere, "Everywhere")],
                                    selection: $palette.scope)
                        .fixedSize()
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 50)
            if !palette.items.isEmpty {
                Rectangle().fill(Design.Studio.line).frame(height: 1)
                results
            }
        }
        .background(Design.Studio.panel, in: shape)
        .overlay(shape.strokeBorder(Design.Studio.line))
        .clipShape(shape)
        .shadow(color: .black.opacity(0.45), radius: 30, y: 12)
    }

    private static let rowHeight: CGFloat = 40
    private static let headerHeight: CGFloat = 26

    private var results: some View {
        let items = palette.items
        let groups = Dictionary(grouping: items.indices, by: { items[$0].kind })
        let height = CGFloat(items.count) * Self.rowHeight + CGFloat(groups.count) * Self.headerHeight + 12
        return ScrollViewReader { scroller in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(SearchPalette.Kind.allCases.filter { groups[$0] != nil }, id: \.self) { kind in
                        Text(kind.title)
                            .font(Design.Studio.hint)
                            .foregroundStyle(Design.Studio.textFaint)
                            .padding(.horizontal, 10)
                            .frame(height: Self.headerHeight, alignment: .bottomLeading)
                        ForEach(groups[kind] ?? [], id: \.self) { index in
                            row(items[index], on: index == palette.selected)
                                .id(items[index].id)
                                .contentShape(Rectangle())
                                .onTapGesture { palette.choose(index) }
                                .onHover { if $0 { palette.selected = index } }
                        }
                    }
                }
                .padding(.horizontal, 6)
                .padding(.bottom, 6)
            }
            .frame(height: min(height, 440))
            .onChange(of: palette.selected) {
                if items.indices.contains(palette.selected) { scroller.scrollTo(items[palette.selected].id) }
            }
        }
    }

    private func row(_ item: SearchPalette.Item, on: Bool) -> some View {
        let pictured = [.library, .file, .photo, .seen, .project].contains(item.kind)
        return HStack(spacing: 10) {
            Group {
                if pictured, let file = item.file {
                    FileThumbnail(file: file, remote: item.picture, audio: item.audio)
                } else {
                    Image(systemName: item.symbol)
                        .font(.system(size: 13))
                        .foregroundStyle(on ? Color.white : Design.Studio.textQuiet)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Design.Studio.raised, in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                }
            }
            .frame(width: pictured ? 48 : 28, height: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(item.title).font(Design.Studio.body).foregroundStyle(on ? Color.white : Design.Studio.text)
                if !item.detail.isEmpty {
                    Text(item.detail).font(Design.Studio.hint).foregroundStyle(on ? Color.white.opacity(0.75) : Design.Studio.textQuiet)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 0)
            if on { Image(systemName: "return").font(Design.Studio.hint).foregroundStyle(Color.white.opacity(0.75)) }
        }
        .padding(.horizontal, 8)
        .frame(height: Self.rowHeight)
        .background {
            if on { RoundedRectangle(cornerRadius: Design.Studio.controlRadius, style: .continuous).fill(Design.Brand.deep) }
        }
    }
}
