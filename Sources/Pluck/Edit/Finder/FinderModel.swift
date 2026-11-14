import AppKit
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

/// How a pane shows its folder, as Finder does (⌘1, ⌘2, ⌘3, ⌘4).
enum FinderViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns, gallery
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .icons: "Icons"
        case .list: "List"
        case .columns: "Columns"
        case .gallery: "Gallery"
        }
    }

    var symbol: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        case .gallery: "rectangle.bottomthird.inset.filled"
        }
    }
}

/// Where a pane's folders come from when they aren't on this Mac's disk (another Mac's share):
/// listed and opened by it, read only (nothing renamed, moved, copied or put in the Trash). Its
/// files' URLs are stand-ins under `root`, which doesn't exist here.
@MainActor
protocol FinderSource: AnyObject {
    var root: URL { get }
    /// A folder's things (put in order by the pane).
    func list(_ folder: URL) async -> [(URL, FinderInfo)]
    /// A double-click, Return or Space on a file (not a folder).
    func open(_ url: URL)
    /// A file's picture (nil: its icon).
    func picture(_ url: URL) async -> CGImage?
    /// What a right-click on these offers.
    func menu(_ urls: [URL]) -> AnyView
}

/// What a file is, read off the main thread (its name, kind, size, date and Finder tags).
struct FinderInfo: Sendable {
    var name: String
    var isFolder: Bool
    var isClip: Bool
    var isPhoto: Bool
    var size: Int64?
    var modified: Date?
    var kind: String
    var tags: [FinderTagMark]

    /// Folders first, then in the order chosen.
    static func precedes(_ a: FinderInfo, _ b: FinderInfo, by sort: FinderPane.Sort, ascending: Bool) -> Bool {
        if a.isFolder != b.isFolder { return a.isFolder }
        let ordered: Bool
        switch sort {
        case .name: ordered = a.name.localizedStandardCompare(b.name) == .orderedAscending
        case .modified: ordered = (a.modified ?? .distantPast) < (b.modified ?? .distantPast)
        case .size: ordered = (a.size ?? 0) < (b.size ?? 0)
        case .kind: ordered = a.kind.localizedStandardCompare(b.kind) == .orderedAscending
        }
        return ascending ? ordered : !ordered
    }
}

/// One thing in a folder: a folder to go into, a clip to play (a file, or a camera's clip
/// folder such as a RED .RDC), or any other file.
@MainActor
@Observable
final class FinderItem: Identifiable {
    nonisolated let url: URL
    nonisolated var id: URL { url }
    nonisolated let info: FinderInfo
    nonisolated var name: String { info.name }
    /// A folder to go into (not a clip folder, an app or a package).
    nonisolated var isFolder: Bool { info.isFolder }
    /// Something Pluck plays (a movie, camera raw, a clip folder).
    nonisolated var isClip: Bool { info.isClip }
    /// A picture (a photo, camera raw, a still), shown in the pane's viewer.
    nonisolated var isPhoto: Bool { info.isPhoto }
    nonisolated var size: Int64? { info.size }
    nonisolated var modified: Date? { info.modified }
    nonisolated var kind: String { info.kind }
    nonisolated var tags: [FinderTagMark] { info.tags }

    init(url: URL, info: FinderInfo) {
        self.url = url
        self.info = info
    }

    /// The system's icon for it (folders, documents), for what has no thumbnail.
    var icon: NSImage {
        // (Not on this Mac, as another Mac's file: by its kind.)
        guard !FileManager.default.fileExists(atPath: url.path) else { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: isFolder ? .folder : UTType(filenameExtension: url.pathExtension) ?? .data)
    }

    /// A file's type for sorting and the Kind column (and its name, as Finder shows it).
    nonisolated static func read(_ url: URL) -> FinderInfo {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey, .localizedNameKey]
        let values = try? url.resourceValues(forKeys: keys)
        let directory = values?.isDirectory == true
        let clipFolder = directory && RawFolderScan.isClipFolder(url)
        let isFolder = directory && values?.isPackage != true && !clipFolder
        let playable = RawFormats.extensions.subtracting(["dng"]).union(RawFolderScan.movieExtensions)
        let isClip = clipFolder || (!directory && (playable.contains(url.pathExtension.lowercased())
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true))
        let isPhoto = !isFolder && !isClip && UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
        return FinderInfo(name: values?.localizedName ?? url.lastPathComponent, isFolder: isFolder, isClip: isClip, isPhoto: isPhoto,
                          size: directory ? nil : values?.fileSize.map(Int64.init), modified: values?.contentModificationDate,
                          kind: clipFolder ? String(localized: "Clip") : values?.localizedTypeDescription ?? "", tags: FinderTags.read(url))
    }

    /// A folder's things, read and put in order off the main thread.
    nonisolated static func list(_ folder: URL, hidden: Bool, sort: FinderPane.Sort, ascending: Bool) -> [(URL, FinderInfo)] {
        let urls = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: hidden ? [] : [.skipsHiddenFiles])) ?? []
        return ordered(urls.map { ($0, read($0)) }, sort: sort, ascending: ascending)
    }

    nonisolated static func ordered(_ read: [(URL, FinderInfo)], sort: FinderPane.Sort, ascending: Bool) -> [(URL, FinderInfo)] {
        read.sorted { FinderInfo.precedes($0.1, $1.1, by: sort, ascending: ascending) }
    }
}

/// Thumbnails and clip details for every pane, made once and kept while Pluck runs (and on
/// disk, by the thumbnailer).
@MainActor
@Observable
final class FinderThumbnails {
    static let shared = FinderThumbnails()

    private(set) var posters: [URL: CGImage] = [:]
    /// Photos' pictures (and any other picture file's), by macOS's own thumbnailer.
    private(set) var pictures: [URL: CGImage] = [:]
    private(set) var summaries: [URL: RawClipSummary] = [:]
    private(set) var failed: Set<URL> = []
    /// The frame under the pointer while skimming a clip.
    private(set) var skimmed: (url: URL, image: CGImage)?
    @ObservationIgnored private var thumbnailer: RawThumbnailer?
    @ObservationIgnored private var asked: Set<URL> = []

    private init() {
        RawTools.prepare()
        thumbnailer = RawThumbnailer { url, summary, image in
            Task { @MainActor in
                let thumbs = FinderThumbnails.shared
                if let image { thumbs.posters[url] = image }
                if let summary { thumbs.summaries[url] = summary } else { thumbs.failed.insert(url) }
            }
        } skimmed: { url, _, image in
            Task { @MainActor in FinderThumbnails.shared.skimmed = (url, image) }
        }
    }

    /// Sources whose files' pictures they make themselves (FinderSource.picture).
    @ObservationIgnored private var sources: [ObjectIdentifier: FinderSource] = [:]

    func register(_ source: FinderSource) { sources[ObjectIdentifier(source)] = source }
    func unregister(_ source: FinderSource) { sources[ObjectIdentifier(source)] = nil }

    private func source(of url: URL) -> FinderSource? { sources.values.first { FinderPane.isInside(url, $0.root) } }

    /// A source's file: its picture asked of it (once). False when the file is this Mac's.
    private func fromSource(_ url: URL, poster: Bool) -> Bool {
        guard let source = source(of: url) else { return false }
        guard (poster ? posters[url] : pictures[url]) == nil, !failed.contains(url), asked.insert(url).inserted else { return true }
        Task {
            if let image = await source.picture(url) { if poster { posters[url] = image } else { keep(image, for: url) } } else { failed.insert(url) }
            asked.remove(url)
        }
        return true
    }

    func want(_ url: URL) {
        wanters[url, default: 0] += 1
        if fromSource(url, poster: true) { return }
        guard posters[url] == nil, !failed.contains(url) else { return }
        asked.insert(url)
        thumbnailer?.want(url)
    }

    func forget(_ url: URL) { if release(url) { thumbnailer?.forget(url) } }

    /// How many show each file now (two rows, or a row and the column view's end, can show one):
    /// its picture is dropped only once none do.
    @ObservationIgnored private var wanters: [URL: Int] = [:]

    /// One fewer shows it; whether that was the last.
    private func release(_ url: URL) -> Bool {
        let left = (wanters[url] ?? 1) - 1
        wanters[url] = left > 0 ? left : nil
        return left <= 0
    }

    @ObservationIgnored private var pictureRequests: [URL: QLThumbnailGenerator.Request] = [:]
    /// The pictures kept, oldest first (a folder of thousands of photos isn't all kept).
    @ObservationIgnored private var pictureOrder: [URL] = []
    private static let picturesKept = 800
    /// A picture's longest side, in pixels (the largest icon at 2x).
    static let pictureSize: CGFloat = 640

    /// A photo's picture, made when it's first shown.
    func wantPicture(_ url: URL) {
        wanters[url, default: 0] += 1
        if fromSource(url, poster: false) { return }
        guard pictures[url] == nil, pictureRequests[url] == nil else { return }
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: Self.pictureSize, height: Self.pictureSize),
                                                   scale: 1, representationTypes: .thumbnail)
        pictureRequests[url] = request
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { thumbnail, _ in
            let image = thumbnail?.cgImage
            Task { @MainActor in
                let thumbs = FinderThumbnails.shared
                // (A request cancelled, answered late, doesn't take the place of one asked since.)
                guard thumbs.pictureRequests[url] === request else { return }
                thumbs.pictureRequests[url] = nil
                if let image { thumbs.keep(image, for: url) }
            }
        }
    }

    /// No longer shown before its picture's made: not made.
    func forgetPicture(_ url: URL) {
        guard release(url), let request = pictureRequests.removeValue(forKey: url) else { return }
        QLThumbnailGenerator.shared.cancel(request)
    }

    private func keep(_ image: CGImage, for url: URL) {
        pictures[url] = image
        pictureOrder.append(url)
        if pictureOrder.count > Self.picturesKept {
            let old = pictureOrder.removeFirst()
            // (Unless it was made again since.)
            if !pictureOrder.contains(old) { pictures[old] = nil }
        }
    }

    func skim(_ url: URL, at fraction: Double) { if source(of: url) == nil { thumbnailer?.skim(url, at: min(max(fraction, 0), 1)) } }

    func endSkim(_ url: URL) { if skimmed?.url == url { skimmed = nil } }

    /// A clip (or photo) changed on disk: its picture is made again.
    func refresh(_ url: URL) {
        posters[url] = nil
        pictures[url] = nil
        summaries[url] = nil
        failed.remove(url)
    }
}

/// One pane: a folder (or a list of clips), how it's shown, what's selected, where it's been,
/// and the clip playing in it.
@MainActor
@Observable
final class FinderPane: Identifiable {
    enum Sort: String, CaseIterable { case name, modified, size, kind }

    let id = UUID()
    /// Where the folders come from when not this Mac's disk (read only).
    let source: FinderSource?
    /// The folder shown (for a list of clips: a stand-in named after the list).
    private(set) var url: URL
    /// Clips listed by themselves (the Library's Clips), instead of a folder's contents.
    private(set) var list: (name: String, urls: [URL])?
    private(set) var items: [FinderItem] = []
    /// What's shown: folders first, then the rest, in the order chosen; filtered by name and tag
    /// (worked out once per change, not per look: a folder can hold thousands).
    private(set) var shown: [FinderItem] = []
    /// Goes up whenever `shown` is worked out again (what views keep their own lists by).
    private(set) var version = 0
    /// The folder's things in the order chosen, and where each is in what's shown.
    @ObservationIgnored private var sorted: [FinderItem] = []
    @ObservationIgnored private var place: [URL: Int] = [:]
    private(set) var loading = false
    var selection: Set<URL> = []
    /// Where a Shift-click run starts.
    var anchor: URL?
    var mode: FinderViewMode {
        didSet { if !applying { UserDefaults.standard.set(mode.rawValue, forKey: "finderViewMode"); remember() } }
    }
    var sort: Sort = .name { didSet { if sort != oldValue { resort(); remember() } } }
    var ascending = true { didSet { if ascending != oldValue { resort(); remember() } } }
    /// The Library's search field: names containing it here at once, then names and text in
    /// files in this folder and below.
    var filter = "" { didSet { if filter != oldValue { search() } } }
    /// Only things with this Finder tag colour (nil: everything).
    var tagFilter: Int? { didSet { if tagFilter != oldValue { reshow() } } }
    /// What a search in this folder and below found (nil: not searching).
    private(set) var results: [FinderItem]?
    private(set) var searching = false
    @ObservationIgnored private var searchTask: Task<Void, Never>?
    @ObservationIgnored private var applying = false
    /// A clip playing in the pane (Esc goes back to the folder).
    var playing: URL?
    /// A photo shown in the pane's viewer (Esc goes back to the folder).
    var viewing: URL?
    /// A name being typed in place: a new folder's, or a file's new one.
    var naming: Naming?
    /// Why a rename, a move or a new folder couldn't be done (shown in an alert).
    var problem: String?
    /// Asking before these go to the Trash.
    var trashing: [URL] = []
    /// Several being renamed at once (the Rename sheet).
    var renamingMany: [URL] = []
    /// A Markdown file read large (Space).
    var reading: URL?
    @ObservationIgnored private var typeSelect = TypeSelect()
    /// Goes up whenever something's opened (a click on a name then doesn't rename it).
    @ObservationIgnored private var opens = 0
    /// The folders above this one shown in the Columns view start here.
    private(set) var base: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(url: URL, base: URL? = nil, source: FinderSource? = nil) {
        self.source = source
        self.url = url
        self.base = base ?? url
        mode = FinderViewMode(rawValue: UserDefaults.standard.string(forKey: "finderViewMode") ?? "") ?? .icons
        applyRemembered()
        load()
    }

    var title: String { list?.name ?? FileManager.default.displayName(atPath: url.path) }
    var canGoBack: Bool { !backStack.isEmpty || playing != nil || viewing != nil }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// The folder's things put in the order chosen again.
    private func resort() {
        sorted = items.sorted { FinderInfo.precedes($0.info, $1.info, by: sort, ascending: ascending) }
        reshow()
    }

    /// What's shown worked out again (the order kept, filtered by name and tag).
    private func reshow() {
        let words = filter.trimmingCharacters(in: .whitespaces)
        var list = results ?? (words.isEmpty ? sorted : sorted.filter { $0.name.localizedCaseInsensitiveContains(words) })
        if let tag = tagFilter { list = list.filter { $0.tags.contains { $0.color == tag } } }
        shown = list
        version += 1
        place = Dictionary(list.enumerated().map { ($1.url, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Where an item is in what's shown.
    func position(of url: URL) -> Int? { place[url] }

    var clips: [URL] { shown.filter(\.isClip).map(\.url) }
    var photos: [URL] { shown.filter(\.isPhoto).map(\.url) }

    // MARK: Going places

    /// Shows a folder. `base`: where the Columns view starts (a sidebar choice resets it).
    func go(to folder: URL, base newBase: URL? = nil, record: Bool = true) {
        let folder = folder.standardizedFileURL
        guard folder != url || list != nil || playing != nil || viewing != nil else {
            // Already here: the Columns view starts where asked.
            if let newBase { base = newBase.standardizedFileURL }
            return
        }
        // (A list of clips isn't a place to go back to.)
        if record { if list == nil { backStack.append(url) }; forwardStack = [] }
        playing = nil
        viewing = nil
        list = nil
        url = folder
        applyRemembered()
        if let newBase { base = newBase.standardizedFileURL } else if !Self.isInside(folder, base) { base = folder }
        selection = []
        // (Not the last folder's things while this one's read.)
        items = []
        load()
    }

    /// Shows clips listed by themselves (not a folder).
    func show(list name: String, urls: [URL]) {
        backStack = []
        forwardStack = []
        playing = nil
        viewing = nil
        list = (name, urls)
        url = URL(fileURLWithPath: "/" + name)
        base = url
        selection = []
        load()
    }

    func goBack() {
        if playing != nil { playing = nil; return }
        if viewing != nil { viewing = nil; return }
        guard let previous = backStack.popLast() else { return }
        forwardStack.append(url)
        go(to: previous, record: false)
    }

    func goForward() {
        guard let next = forwardStack.popLast() else { return }
        backStack.append(url)
        go(to: next, record: false)
    }

    /// The folder this one is in (⌘↑), the one left selected.
    func goUp() {
        guard list == nil else { return }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path, source == nil || Self.isInside(parent, base) else { return }
        let from = url
        go(to: parent)
        selection = [from]
        anchor = from
    }

    /// A folder goes in, a clip plays, a photo shows in the viewer, anything else opens in its own app.
    func open(_ item: FinderItem) {
        opens += 1
        if let source, !item.isFolder { selection = [item.url]; anchor = item.url; source.open(item.url); return }
        if item.isFolder { go(to: item.url) }
        else if item.isClip { playing = item.url; selection = [item.url] }
        else if item.isPhoto { viewing = item.url; selection = [item.url]; anchor = item.url }
        else { NSWorkspace.shared.open(item.url) }
    }

    /// The viewer on the photo before or after (`step` -1 or 1), staying on the last one at an end.
    func view(by step: Int) {
        let list = photos
        guard let viewing, let index = list.firstIndex(of: viewing) else { return }
        let next = list[min(max(index + step, 0), list.count - 1)]
        self.viewing = next
        selection = [next]
        anchor = next
    }

    /// A file from a folder before this one in the columns: that folder becomes the pane's
    /// first (so a clip plays with its own folder's clips around it).
    func open(_ item: FinderItem, in folder: URL) {
        go(to: folder)
        selection = [item.url]
        anchor = item.url
        if source == nil, item.isClip || item.isPhoto {
            Task {
                while loading { try? await Task.sleep(for: .milliseconds(30)) }
                if item.isClip { playing = item.url } else { viewing = item.url }
            }
        } else {
            open(item)
        }
    }

    /// The first thing in the folder, once it's read (after going into it with the keys).
    func selectFirst() {
        Task {
            while loading { try? await Task.sleep(for: .milliseconds(30)) }
            if selection.isEmpty, let first = shown.first { selection = [first.url]; anchor = first.url }
        }
    }

    func openSelection() {
        let chosen = shown.filter { selection.contains($0.url) }
        if chosen.count == 1, let only = chosen.first { open(only); return }
        if let source { if let file = chosen.first(where: { !$0.isFolder }) { source.open(file.url) }; return }
        for item in chosen where !item.isFolder && !item.isClip && !item.isPhoto { NSWorkspace.shared.open(item.url) }
        if let clip = chosen.first(where: \.isClip) { playing = clip.url }
        else if let photo = chosen.first(where: \.isPhoto) { viewing = photo.url }
    }

    // MARK: Selecting

    /// A click: on its own, ⌘ adds or takes away, ⇧ selects the run from the last one.
    func click(_ item: FinderItem, modifiers: EventModifiers) {
        if modifiers.contains(.command) {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
            anchor = item.url
        } else if modifiers.contains(.shift), let anchor, let from = place[anchor], let to = place[item.url] {
            selection = Set(shown[min(from, to)...max(from, to)].map(\.url))
        } else {
            selection = [item.url]
            anchor = item.url
        }
    }

    /// Tiles in a row of a pane's Icons view (for the up and down arrows).
    static func iconColumns(_ pane: FinderPane) -> Int {
        let width = FinderWorkspace.shared.frames[pane.id]?.width ?? 800
        let size = UserDefaults.standard.object(forKey: "finderIconSize") as? Double ?? 170
        return max(Int((width - 32) / (size + 14)), 1)
    }

    /// The arrow keys: `step` places on (1, -1, or a row's worth in the Icons view).
    func move(by step: Int, extend: Bool = false) {
        let list = shown
        guard !list.isEmpty else { return }
        let current = (anchor ?? selection.first).flatMap { place[$0] }
        let next = current.map { min(max($0 + step, 0), list.count - 1) } ?? (step > 0 ? 0 : list.count - 1)
        if extend { selection.insert(list[next].url) } else { selection = [list[next].url] }
        anchor = list[next].url
    }

    func selectAll() { selection = Set(shown.map(\.url)) }

    /// Letters typed: the first name starting with them is selected.
    func jump(_ characters: String) {
        let list = shown
        guard let index = TypeSelect.match(typeSelect.add(characters), in: list.lazy.map(\.name)) else { return }
        selection = [list[index].url]
        anchor = list[index].url
    }

    /// Return, or a click on the name of the one selected: its name is typed in place.
    func beginRename() {
        guard list == nil, source == nil else { return }
        if selection.count > 1 { renamingMany = chosen; return }
        guard let url = selection.first else { return }
        naming = .rename(url)
    }

    /// What's selected, in the order shown.
    var chosen: [URL] { shown.map(\.url).filter { selection.contains($0) } }

    /// Space: a Markdown file read large, anything else in Quick Look.
    func quickLook() {
        if source != nil { openSelection(); return }
        if selection.count == 1, let one = selection.first, FilePreview.isMarkdown(one), !FinderQuickLook.shared.isOpen {
            reading = one
        } else {
            FinderQuickLook.shared.toggle(self)
        }
    }

    /// A zip of these beside them ("name.zip", or "Archive.zip" for several), selected.
    func compress(_ urls: [URL]) {
        Task {
            switch await FinderArchive.compress(urls) {
            case .success(let zip): selection = [zip]; anchor = zip
            case .failure(let failed): problem = failed.errorDescription
            }
        }
    }

    /// What's in a zip, beside it, selected.
    func uncompress(_ zip: URL) {
        Task {
            switch await FinderArchive.uncompress(zip) {
            case .success(let placed): selection = Set(placed); anchor = placed.first
            case .failure(let failed): problem = failed.errorDescription
            }
        }
    }

    /// A click on a selected item's name: renamed in place, unless it was a double-click's first.
    func renameSoon(_ url: URL) {
        let before = opens
        Task {
            try? await Task.sleep(for: .seconds(NSEvent.doubleClickInterval + 0.1))
            guard opens == before, selection == [url], playing == nil, viewing == nil, naming == nil else { return }
            beginRename()
        }
    }

    // MARK: Loading

    func reload() { load() }

    private func load() {
        loadTask?.cancel()
        watcher = nil
        loading = true
        let folder = url, listed = list?.urls, sort = sort, ascending = ascending, hidden = Self.showsHidden, source = source
        loadTask = Task {
            // (Read and put in order off the main thread: a folder can hold thousands.)
            let read = if let source { FinderItem.ordered(await source.list(folder), sort: sort, ascending: ascending) } else { await Task.detached(priority: .userInitiated) { () -> [(URL, FinderInfo)] in
                let all = listed.map { urls in FinderItem.ordered(urls.map { ($0, FinderItem.read($0)) }, sort: sort, ascending: ascending) }
                    ?? FinderItem.list(folder, hidden: hidden, sort: sort, ascending: ascending)
                // A RED take's later parts (_002.R3D…) belong to its first.
                return all.filter { url, _ in
                    guard url.pathExtension.lowercased() == "r3d",
                          let part = url.deletingPathExtension().lastPathComponent.split(separator: "_").last, part.count == 3,
                          let number = Int(part) else { return true }
                    return number <= 1
                }
            }.value }
            guard !Task.isCancelled else { return }
            let before = Dictionary(items.map { ($0.url, $0.info) }, uniquingKeysWith: { a, _ in a })
            let selected = selection
            items = read.map { FinderItem(url: $0.0, info: $0.1) }
            // Changed elsewhere since it was last read: its picture is made again.
            for item in items {
                if let old = before[item.url], old.modified != item.modified || old.size != item.size { FinderThumbnails.shared.refresh(item.url) }
            }
            if sort == self.sort, ascending == self.ascending { sorted = items; reshow() } else { resort() }
            selection = selected.intersection(Set(items.map(\.url)).union(results?.map(\.url) ?? []))
            loading = false
            if !filter.trimmingCharacters(in: .whitespaces).isEmpty { search(wait: false) }
            // Changes on disk (a copy arriving, a file renamed) show by themselves.
            if listed == nil, source == nil {
                // (The events give the real path: /private/var for /var.)
                let watched: Set<String> = [folder.path, realpath(folder.path, nil).map { String(cString: $0) } ?? folder.path]
                watcher = FolderWatcher(path: folder.path) { [weak self] paths in
                    // (Only what's in this folder itself, not every change below it.)
                    guard paths.contains(where: { watched.contains(($0 as NSString).deletingLastPathComponent) || watched.contains(($0 as NSString).standardizingPath) })
                    else { return }
                    Task { @MainActor in self?.refreshQuietly() }
                }
            }
        }
    }

    // MARK: Hidden files, and each folder's own view

    /// Files whose names start with a dot, shown (⇧⌘.).
    static var showsHidden: Bool { UserDefaults.standard.bool(forKey: "finderShowHidden") }

    static func toggleHidden() {
        UserDefaults.standard.set(!showsHidden, forKey: "finderShowHidden")
        for pane in FinderWorkspace.shared.panes { pane.reload() }
    }

    /// Each folder keeps its view and order, as in Finder (the last few hundred folders).
    private static let viewsKey = "finderFolderViews"
    private static let viewsKept = 300

    private func remember() {
        guard !applying, list == nil else { return }
        var saved = UserDefaults.standard.array(forKey: Self.viewsKey) as? [[String]] ?? []
        saved.removeAll { $0.first == url.path }
        saved.append([url.path, mode.rawValue, sort.rawValue, ascending ? "1" : "0"])
        if saved.count > Self.viewsKept { saved.removeFirst(saved.count - Self.viewsKept) }
        UserDefaults.standard.set(saved, forKey: Self.viewsKey)
    }

    private func applyRemembered() {
        guard list == nil, let saved = (UserDefaults.standard.array(forKey: Self.viewsKey) as? [[String]])?.last(where: { $0.first == url.path }),
              saved.count == 4 else { return }
        applying = true
        defer { applying = false }
        if let chosen = FinderViewMode(rawValue: saved[1]) { mode = chosen }
        if let order = Sort(rawValue: saved[2]) { sort = order }
        ascending = saved[3] == "1"
    }

    // MARK: Searching

    /// Names containing the search, here at once; then (after typing stops) names and text in
    /// files in this folder and below (Spotlight), in the same views. Cleared: the folder again.
    private func search(wait: Bool = true) {
        searchTask?.cancel()
        let words = filter.trimmingCharacters(in: .whitespaces)
        // (A source's folder: by name, here only.)
        guard !words.isEmpty, list == nil, source == nil else {
            results = nil
            searching = false
            reshow()
            return
        }
        if wait { results = nil }
        reshow()
        searching = true
        let folder = url, hidden = Self.showsHidden, sort = sort, ascending = ascending
        searchTask = Task {
            if wait { try? await Task.sleep(for: .milliseconds(250)) }
            guard !Task.isCancelled else { return }
            async let named = Self.names(containing: words, in: folder, hidden: hidden)
            let inside = await Self.spotlight(words, in: folder, hidden: hidden)
            let found = await named
            guard !Task.isCancelled else { return }
            var seen = Set(found.map(\.path))
            let urls = found + inside.filter { seen.insert($0.path).inserted }
            let read = await Task.detached(priority: .userInitiated) { FinderItem.ordered(urls.map { ($0, FinderItem.read($0)) }, sort: sort, ascending: ascending) }.value
            guard !Task.isCancelled else { return }
            results = read.map { FinderItem(url: $0.0, info: $0.1) }
            searching = false
            reshow()
        }
    }

    /// The most a search lists (and looks through), so a search of a whole drive stays quick.
    nonisolated static let searchLimit = 2000

    /// Things in a folder and below whose names contain `words` (no Spotlight needed).
    nonisolated static func names(containing words: String, in folder: URL, hidden: Bool) async -> [URL] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: nil,
                                                          options: hidden ? [.skipsPackageDescendants] : [.skipsHiddenFiles, .skipsPackageDescendants])
        else { return [] }
        var found: [URL] = [], looked = 0
        while let url = walker.nextObject() as? URL, found.count < searchLimit, looked < 300_000 {
            looked += 1
            if looked % 500 == 0, Task.isCancelled { break }
            if url.lastPathComponent.localizedCaseInsensitiveContains(words) { found.append(url) }
        }
        return found
    }

    /// Files in a folder and below with `words` in them, as Spotlight knows them (none where it doesn't).
    static func spotlight(_ words: String, in folder: URL, hidden: Bool) async -> [URL] {
        let query = NSMetadataQuery()
        query.searchScopes = [folder]
        query.predicate = NSPredicate(format: "%K CONTAINS[cd] %@", "kMDItemTextContent", words)
        let paths: [String] = await withCheckedContinuation { done in
            var token: NSObjectProtocol?
            var finished = false
            func finish(_ paths: [String]) {
                guard !finished else { return }
                finished = true
                query.stop()
                if let token { NotificationCenter.default.removeObserver(token) }
                done.resume(returning: paths)
            }
            token = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { _ in
                MainActor.assumeIsolated {
                    query.disableUpdates()
                    finish((0..<min(query.resultCount, searchLimit)).compactMap { (query.result(at: $0) as? NSMetadataItem)?.value(forAttribute: NSMetadataItemPathKey) as? String })
                }
            }
            if !query.start() { finish([]) }
            // (Spotlight off for that drive, or slow: not waited on for ever.)
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(10))
                finish([])
            }
        }
        return paths.filter { hidden || !$0.contains("/.") }.map { URL(fileURLWithPath: $0) }
    }

    @ObservationIgnored private var quietTask: Task<Void, Never>?

    /// Read again after changes on disk settle (the last of a burst is never missed).
    private func refreshQuietly() {
        quietTask?.cancel()
        quietTask = Task {
            // (A big folder is read whole each time: changes arriving during a copy aren't re-read every moment.)
            try? await Task.sleep(for: .milliseconds(items.count > 2000 ? 3000 : 400))
            guard !Task.isCancelled else { return }
            load()
        }
    }

    // MARK: Files

    /// ⌘⌫: asks, then the selected files go to the Trash (they can be put back from there).
    func trashSelection() {
        guard !selection.isEmpty, source == nil else { return }
        trashing = shown.map(\.url).filter { selection.contains($0) }
    }

    func trash(_ urls: [URL]) {
        trashing = []
        if let failed = FinderFiles.trash(urls) { problem = failed }
        selection.subtract(urls)
    }

    func copySelection() {
        guard source == nil else { return }
        FinderFiles.copyToPasteboard(shown.map(\.url).filter { selection.contains($0) })
    }

    /// ⌘D: a copy of each selected file beside it, the copies selected.
    func duplicateSelection() {
        guard list == nil, source == nil else { return }
        let chosen = shown.map(\.url).filter { selection.contains($0) }
        var made: Set<URL> = []
        FileUndo.shared.grouped(String(localized: "Duplicate")) {
            for url in chosen where !url.hasDirectoryPath && !FinderFiles.isBig(url) {
                do { made.insert(try FinderFiles.duplicateNow(url, to: FinderFiles.copyName(for: url))) } catch { problem = error.localizedDescription }
            }
        }
        // (A folder is copied off the main thread; a big file in the background, with a bar at the Library's foot.)
        for url in chosen where url.hasDirectoryPath || FinderFiles.isBig(url) {
            Task {
                do { _ = try await FinderFiles.duplicate(url); load() } catch { problem = error.localizedDescription }
            }
        }
        guard !made.isEmpty else { return }
        load()
        selection = made
        anchor = made.first
    }

    /// ⇧⌘N, as Finder: "untitled folder" made, selected, its name typed over.
    func newFolderInPlace() {
        guard list == nil, source == nil else { return }
        let name = freeFolderName
        if let failed = newFolder(named: name) { problem = failed; return }
        naming = .rename(url.appendingPathComponent(name, isDirectory: true))
    }

    /// Files copied (here or in Finder) into this folder: checked like an offload. `move` (⌥⌘V):
    /// moved here instead.
    func paste(move: Bool = false) {
        guard list == nil, source == nil, let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        LibraryPanes.shared.copy(urls, into: url, move: move)
    }

    /// What's being named in place (a new folder is made first, then named like any other).
    enum Naming: Equatable {
        case rename(URL)
    }

    /// A name Finder would take: not empty, no slash or colon, not starting with a dot.
    nonisolated static func nameProblem(_ name: String) -> String? {
        let name = name.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { return String(localized: "Type a name.") }
        if name.contains("/") || name.contains(":") { return String(localized: "A name can’t contain “/” or “:”.") }
        if name.hasPrefix(".") { return String(localized: "Names that begin with a dot are hidden. Choose another name.") }
        return nil
    }

    /// A new folder here, named `name`, selected. Nil when made; else why it couldn't be.
    @discardableResult
    func newFolder(named name: String) -> String? {
        guard list == nil else { return nil }
        if let problem = Self.nameProblem(name) { return problem }
        let folder = url.appendingPathComponent(name.trimmingCharacters(in: .whitespaces), isDirectory: true)
        if FileManager.default.fileExists(atPath: folder.path) {
            return String(localized: "\(folder.lastPathComponent) is already in \(title).")
        }
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            return error.localizedDescription
        }
        FileUndo.shared.record(String(localized: "New Folder"), undo: [.trash(folder)])
        load()
        selection = [folder]
        anchor = folder
        return nil
    }

    /// A name for a new folder here that isn't taken ("untitled folder", "untitled folder 2"…).
    var freeFolderName: String {
        let base = String(localized: "untitled folder")
        var name = base, number = 2
        while FileManager.default.fileExists(atPath: url.appendingPathComponent(name).path) {
            name = "\(base) \(number)"
            number += 1
        }
        return name
    }

    /// A file or folder here renamed. Nil when renamed; else why it couldn't be.
    @discardableResult
    func rename(_ item: URL, to name: String) -> String? {
        let target: URL
        do {
            target = try FinderFiles.rename(item, to: name)
        } catch {
            return error.localizedDescription
        }
        guard target != item else { return nil }
        load()
        selection = [target]
        anchor = target
        return nil
    }

    /// The folders from the Columns view's start to here.
    var trail: [URL] {
        guard list == nil else { return [url] }
        var chain: [URL] = [url]
        var at = url
        while at.path != base.path, Self.isInside(at, base), at.path != "/" {
            at = at.deletingLastPathComponent()
            chain.insert(at, at: 0)
        }
        return chain
    }

    /// Whether a folder is the other or inside it (by whole folder names: /Volumes/A isn't in /Volumes/AB).
    nonisolated static func isInside(_ url: URL, _ folder: URL) -> Bool {
        let path = url.standardizedFileURL.path, base = folder.standardizedFileURL.path
        return path == base || path.hasPrefix(base == "/" ? "/" : base + "/")
    }

    /// The whole path, for the path bar (from the drive, or the home folder).
    var pathComponents: [URL] {
        guard list == nil else { return [url] }
        if source != nil { return trail }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        var chain: [URL] = []
        var at = url
        while true {
            chain.insert(at, at: 0)
            if at.path == home || at.path == "/" || (at.path.hasPrefix("/Volumes/") && at.pathComponents.count <= 3) { break }
            at = at.deletingLastPathComponent()
        }
        return chain
    }
}

/// The panes, tiled as a tiling window manager does (i3, Sway): each split in two, right or
/// below, up to four; the keyboard moves between them.
@MainActor
@Observable
final class FinderWorkspace {
    static let shared = FinderWorkspace()
    static let maxPanes = 4

    /// A tile: a pane, or two tiles side by side (or one over the other).
    @MainActor
    @Observable
    final class Tile: Identifiable {
        let id = UUID()
        var pane: FinderPane?
        var axis: Axis = .horizontal
        /// How much of the split the first goes to.
        var fraction: CGFloat = 0.5
        var children: [Tile] = []
        weak var parent: Tile?

        init(pane: FinderPane) { self.pane = pane }
        init(axis: Axis, children: [Tile]) {
            self.axis = axis
            self.children = children
            for child in children { child.parent = self }
        }

        var panes: [FinderPane] { pane.map { [$0] } ?? children.flatMap(\.panes) }
    }

    private(set) var root: Tile
    private(set) var focusedID: UUID
    /// Where each pane is on screen (for moving between them with the arrows).
    @ObservationIgnored var frames: [UUID: CGRect] = [:]

    private init() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let pane = FinderPane(url: home)
        root = Tile(pane: pane)
        focusedID = pane.id
    }

    var panes: [FinderPane] { root.panes }
    var focused: FinderPane { panes.first { $0.id == focusedID } ?? panes[0] }

    func focus(_ pane: FinderPane) { focusedID = pane.id }

    private func tile(of pane: FinderPane, in tile: Tile? = nil) -> Tile? {
        let tile = tile ?? root
        if tile.pane === pane { return tile }
        for child in tile.children { if let found = self.tile(of: pane, in: child) { return found } }
        return nil
    }

    /// The pane in front split in two: a new pane beside it (or below), on the same folder.
    func split(_ axis: Axis) {
        guard panes.count < Self.maxPanes, let tile = tile(of: focused), let pane = tile.pane else { return }
        let copy = FinderPane(url: pane.url, base: pane.base)
        copy.mode = pane.mode
        let first = Tile(pane: pane), second = Tile(pane: copy)
        tile.pane = nil
        tile.axis = axis
        tile.children = [first, second]
        first.parent = tile
        second.parent = tile
        focusedID = copy.id
    }

    /// The split the pane in front is in, turned: side by side becomes one above the other, and back.
    func turn() {
        guard let parent = tile(of: focused)?.parent else { return }
        parent.axis = parent.axis == .horizontal ? .vertical : .horizontal
    }

    /// How a pane is split from its neighbour (nil: there's one pane).
    func axis(of pane: FinderPane) -> Axis? { tile(of: pane)?.parent?.axis }

    /// The pane in front closed (the last one stays).
    func close() {
        guard panes.count > 1, let tile = tile(of: focused), let parent = tile.parent else { return }
        let others = parent.children.filter { $0 !== tile }
        guard let sibling = others.first else { return }
        parent.pane = sibling.pane
        parent.axis = sibling.axis
        parent.fraction = sibling.fraction
        parent.children = sibling.children
        for child in parent.children { child.parent = parent }
        focusedID = parent.panes.first?.id ?? panes[0].id
    }

    /// The pane in a direction from the one in front (by where they are on screen).
    private func neighbour(_ direction: Direction) -> FinderPane? {
        guard let here = frames[focusedID] else { return nil }
        let candidates = panes.filter { $0.id != focusedID }.compactMap { pane -> (FinderPane, CGFloat)? in
            guard let frame = frames[pane.id] else { return nil }
            let dx = frame.midX - here.midX, dy = frame.midY - here.midY
            switch direction {
            case .left: guard frame.maxX <= here.minX + 1 else { return nil }
            case .right: guard frame.minX >= here.maxX - 1 else { return nil }
            case .up: guard frame.maxY <= here.minY + 1 else { return nil }
            case .down: guard frame.minY >= here.maxY - 1 else { return nil }
            }
            return (pane, dx * dx + dy * dy)
        }
        return candidates.min { $0.1 < $1.1 }?.0
    }

    enum Direction { case left, right, up, down }

    func move(_ direction: Direction) {
        if let pane = neighbour(direction) { focusedID = pane.id }
    }

    /// The pane in front and the one in a direction change places.
    func swap(_ direction: Direction) {
        guard let other = neighbour(direction), let a = tile(of: focused), let b = tile(of: other) else { return }
        let pane = a.pane
        a.pane = b.pane
        b.pane = pane
    }

    /// The pane that isn't in front, when there are two (where copies go).
    var other: FinderPane? { panes.count == 2 ? panes.first { $0.id != focusedID } : nil }
}
