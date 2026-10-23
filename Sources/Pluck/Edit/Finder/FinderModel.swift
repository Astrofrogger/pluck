import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// How a pane shows its folder, as Finder does (⌘1, ⌘2, ⌘3).
enum FinderViewMode: String, CaseIterable, Identifiable {
    case icons, list, columns
    var id: String { rawValue }

    var title: LocalizedStringKey {
        switch self {
        case .icons: "Icons"
        case .list: "List"
        case .columns: "Columns"
        }
    }

    var symbol: String {
        switch self {
        case .icons: "square.grid.2x2"
        case .list: "list.bullet"
        case .columns: "rectangle.split.3x1"
        }
    }
}

/// One thing in a folder: a folder to go into, a clip to play (a file, or a camera's clip
/// folder such as a RED .RDC), or any other file.
@MainActor
@Observable
final class FinderItem: Identifiable {
    nonisolated let url: URL
    nonisolated var id: URL { url }
    let name: String
    /// A folder to go into (not a clip folder, an app or a package).
    let isFolder: Bool
    /// Something Pluck plays (a movie, camera raw, a clip folder).
    let isClip: Bool
    let size: Int64?
    let modified: Date?
    let kind: String

    init(url: URL, isFolder: Bool, isClip: Bool, size: Int64?, modified: Date?, kind: String) {
        self.url = url
        self.name = FileManager.default.displayName(atPath: url.path)
        self.isFolder = isFolder
        self.isClip = isClip
        self.size = size
        self.modified = modified
        self.kind = kind
    }

    /// The system's icon for it (folders, documents), for what has no thumbnail.
    var icon: NSImage { NSWorkspace.shared.icon(forFile: url.path) }

    /// A file's type for sorting and the Kind column.
    nonisolated static func read(_ url: URL) -> (isFolder: Bool, isClip: Bool, size: Int64?, modified: Date?, kind: String) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isPackageKey, .fileSizeKey, .contentModificationDateKey, .localizedTypeDescriptionKey]
        let values = try? url.resourceValues(forKeys: keys)
        let directory = values?.isDirectory == true
        let clipFolder = directory && RawFolderScan.isClipFolder(url)
        let isFolder = directory && values?.isPackage != true && !clipFolder
        let playable = RawFormats.extensions.subtracting(["dng"]).union(RawFolderScan.movieExtensions)
        let isClip = clipFolder || (!directory && (playable.contains(url.pathExtension.lowercased())
            || UTType(filenameExtension: url.pathExtension)?.conforms(to: .movie) == true))
        return (isFolder, isClip, directory ? nil : values?.fileSize.map(Int64.init), values?.contentModificationDate,
                clipFolder ? String(localized: "Clip") : values?.localizedTypeDescription ?? "")
    }
}

/// Thumbnails and clip details for every pane, made once and kept while Pluck runs (and on
/// disk, by the thumbnailer).
@MainActor
@Observable
final class FinderThumbnails {
    static let shared = FinderThumbnails()

    private(set) var posters: [URL: CGImage] = [:]
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

    func want(_ url: URL) {
        guard posters[url] == nil, !failed.contains(url) else { return }
        asked.insert(url)
        thumbnailer?.want(url)
    }

    func forget(_ url: URL) { thumbnailer?.forget(url) }

    func skim(_ url: URL, at fraction: Double) { thumbnailer?.skim(url, at: min(max(fraction, 0), 1)) }

    func endSkim(_ url: URL) { if skimmed?.url == url { skimmed = nil } }

    /// A clip changed on disk: its picture is made again.
    func refresh(_ url: URL) {
        posters[url] = nil
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
    /// The folder shown (for a list of clips: a stand-in named after the list).
    private(set) var url: URL
    /// Clips listed by themselves (the Library's Clips), instead of a folder's contents.
    private(set) var list: (name: String, urls: [URL])?
    private(set) var items: [FinderItem] = []
    private(set) var loading = false
    var selection: Set<URL> = []
    /// Where a Shift-click run starts.
    var anchor: URL?
    var mode: FinderViewMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "finderViewMode") }
    }
    var sort: Sort = .name
    var ascending = true
    /// Names containing this (the Library's search field, for the pane in front).
    var filter = ""
    /// A clip playing in the pane (Esc goes back to the folder).
    var playing: URL?
    /// The folders above this one shown in the Columns view start here.
    private(set) var base: URL
    private var backStack: [URL] = []
    private var forwardStack: [URL] = []
    @ObservationIgnored private var watcher: FolderWatcher?
    @ObservationIgnored private var loadTask: Task<Void, Never>?

    init(url: URL, base: URL? = nil) {
        self.url = url
        self.base = base ?? url
        mode = FinderViewMode(rawValue: UserDefaults.standard.string(forKey: "finderViewMode") ?? "") ?? .icons
        load()
    }

    var title: String { list?.name ?? FileManager.default.displayName(atPath: url.path) }
    var canGoBack: Bool { !backStack.isEmpty || playing != nil }
    var canGoForward: Bool { !forwardStack.isEmpty }

    /// What's shown: folders first, then the rest, in the order chosen; filtered by name.
    var shown: [FinderItem] {
        let words = filter.trimmingCharacters(in: .whitespaces)
        let visible = words.isEmpty ? items : items.filter { $0.name.localizedCaseInsensitiveContains(words) }
        return visible.sorted { a, b in
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

    var clips: [URL] { shown.filter(\.isClip).map(\.url) }

    // MARK: Going places

    /// Shows a folder. `base`: where the Columns view starts (a sidebar choice resets it).
    func go(to folder: URL, base newBase: URL? = nil, record: Bool = true) {
        let folder = folder.standardizedFileURL
        guard folder != url || list != nil || playing != nil else {
            // Already here: the Columns view starts where asked.
            if let newBase { base = newBase.standardizedFileURL }
            return
        }
        // (A list of clips isn't a place to go back to.)
        if record { if list == nil { backStack.append(url) }; forwardStack = [] }
        playing = nil
        list = nil
        url = folder
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
        list = (name, urls)
        url = URL(fileURLWithPath: "/" + name)
        base = url
        selection = []
        load()
    }

    func goBack() {
        if playing != nil { playing = nil; return }
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
        guard parent.path != url.path else { return }
        let from = url
        go(to: parent)
        selection = [from]
        anchor = from
    }

    /// A folder goes in, a clip plays, anything else opens in its own app.
    func open(_ item: FinderItem) {
        if item.isFolder { go(to: item.url) }
        else if item.isClip { playing = item.url; selection = [item.url] }
        else { NSWorkspace.shared.open(item.url) }
    }

    /// A file from a folder before this one in the columns: that folder becomes the pane's
    /// first (so a clip plays with its own folder's clips around it).
    func open(_ item: FinderItem, in folder: URL) {
        go(to: folder)
        selection = [item.url]
        anchor = item.url
        if item.isClip {
            Task {
                while loading { try? await Task.sleep(for: .milliseconds(30)) }
                playing = item.url
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
        for item in chosen where !item.isFolder && !item.isClip { NSWorkspace.shared.open(item.url) }
        if let clip = chosen.first(where: \.isClip) { playing = clip.url }
    }

    // MARK: Selecting

    /// A click: on its own, ⌘ adds or takes away, ⇧ selects the run from the last one.
    func click(_ item: FinderItem, modifiers: EventModifiers) {
        if modifiers.contains(.command) {
            if selection.contains(item.url) { selection.remove(item.url) } else { selection.insert(item.url) }
            anchor = item.url
        } else if modifiers.contains(.shift), let anchor, let from = shown.firstIndex(where: { $0.url == anchor }),
                  let to = shown.firstIndex(where: { $0.url == item.url }) {
            selection = Set(shown[min(from, to)...max(from, to)].map(\.url))
        } else {
            selection = [item.url]
            anchor = item.url
        }
    }

    /// The arrow keys: `step` places on (1, -1, or a row's worth in the Icons view).
    func move(by step: Int, extend: Bool = false) {
        let list = shown
        guard !list.isEmpty else { return }
        let current = list.firstIndex { $0.url == (anchor ?? selection.first) }
        let next = current.map { min(max($0 + step, 0), list.count - 1) } ?? (step > 0 ? 0 : list.count - 1)
        if extend { selection.insert(list[next].url) } else { selection = [list[next].url] }
        anchor = list[next].url
    }

    func selectAll() { selection = Set(shown.map(\.url)) }

    // MARK: Loading

    func reload() { load() }

    private func load() {
        loadTask?.cancel()
        watcher = nil
        loading = true
        let folder = url, listed = list?.urls
        loadTask = Task {
            let read = await Task.detached(priority: .userInitiated) { () -> [(URL, (isFolder: Bool, isClip: Bool, size: Int64?, modified: Date?, kind: String))] in
                let urls = listed ?? ((try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? [])
                return urls.map { ($0, FinderItem.read($0)) }
                    // A RED take's later parts (_002.R3D…) belong to its first.
                    .filter { url, _ in
                        guard url.pathExtension.lowercased() == "r3d",
                              let part = url.deletingPathExtension().lastPathComponent.split(separator: "_").last, part.count == 3,
                              let number = Int(part) else { return true }
                        return number <= 1
                    }
            }.value
            guard !Task.isCancelled else { return }
            let selected = selection
            items = read.map { FinderItem(url: $0.0, isFolder: $0.1.isFolder, isClip: $0.1.isClip, size: $0.1.size, modified: $0.1.modified, kind: $0.1.kind) }
            selection = selected.intersection(Set(items.map(\.url)))
            loading = false
            // Changes on disk (a copy arriving, a file renamed) show by themselves.
            if listed == nil {
                watcher = FolderWatcher(path: folder.path) { [weak self] in
                    Task { @MainActor in self?.refreshQuietly() }
                }
            }
        }
    }

    @ObservationIgnored private var quietTask: Task<Void, Never>?

    /// Read again after changes on disk settle (the last of a burst is never missed).
    private func refreshQuietly() {
        quietTask?.cancel()
        quietTask = Task {
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            load()
        }
    }

    // MARK: Files

    /// The selected files to the Trash (they can be put back from there).
    func trashSelection() {
        let urls = Array(selection)
        guard !urls.isEmpty else { return }
        NSWorkspace.shared.recycle(urls) { _, _ in }
        selection = []
    }

    func copySelection() {
        let urls = shown.filter { selection.contains($0.url) }.map { $0.url as NSURL }
        guard !urls.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects(urls)
    }

    /// Files copied (here or in Finder) into this folder: checked like an offload.
    func paste() {
        guard list == nil, let urls = NSPasteboard.general.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
              !urls.isEmpty else { return }
        LibraryPanes.shared.copy(urls, into: url)
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

    /// The pane in front closed (the last one stays).
    func close() {
        guard panes.count > 1, let tile = tile(of: focused), let parent = tile.parent else { return }
        let others = parent.children.filter { $0 !== tile }
        guard let sibling = others.first else { return }
        parent.pane = sibling.pane
        parent.axis = sibling.axis
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
