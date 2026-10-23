import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Folders (and single clips) the user put in the Library: every video, song and photo in them
/// (and in their folders) is indexed so Search finds it, and new files are picked up as they
/// arrive. Nothing is copied: the files stay where they are. Search can look in one of them only,
/// like a project.
@MainActor
@Observable
final class FootageFolders {
    static let shared = FootageFolders()

    struct Folder: Codable, Identifiable, Hashable {
        var id = UUID()
        var path: String
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
        var url: URL { URL(fileURLWithPath: path, isDirectory: !isFile) }
        /// One clip rather than a folder (a camera's clip folder, .RDC, counts as a clip).
        var isFile: Bool {
            var directory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &directory) else { return URL(fileURLWithPath: path).pathExtension != "" }
            return !directory.boolValue || RawFolderScan.isClipFolder(URL(fileURLWithPath: path))
        }
        /// The drive it's on is plugged in.
        var isThere: Bool { FileManager.default.fileExists(atPath: path) }
    }

    private(set) var folders: [Folder] = [] {
        didSet { refreshPresence() }
    }
    /// Which folders' drives are plugged in, and which are single clips: read off the main
    /// thread (a drive or server that's slow to answer doesn't hold up the sidebar). Nil: not yet read.
    private(set) var present: Set<UUID>?
    private(set) var singles: Set<UUID>?
    /// What's in each folder, by folder: videos (and songs) and photos.
    private(set) var videos: [UUID: [String]] = [:]
    private(set) var photos: [UUID: [String]] = [:]
    private(set) var scanning: Set<UUID> = []

    private static let key = "footageFolders"
    @ObservationIgnored private var watchers: [UUID: FolderWatcher] = [:]
    @ObservationIgnored private var pending: [UUID: Task<Void, Never>] = [:]

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.key), let saved = try? JSONDecoder().decode([Folder].self, from: data) {
            folders = saved
        }
        refreshPresence()
    }

    /// Read again which folders are there (after a drive comes or goes).
    func refreshPresence() {
        let all = folders
        Task {
            let (there, files) = await Task.detached(priority: .userInitiated) { () -> (Set<UUID>, Set<UUID>) in
                (Set(all.filter(\.isThere).map(\.id)), Set(all.filter(\.isFile).map(\.id)))
            }.value
            present = there
            singles = files
        }
    }

    /// Whether a folder's drive is plugged in (as last read; until then, yes).
    func isThere(_ folder: Folder) -> Bool { present?.contains(folder.id) ?? true }

    /// A single clip rather than a folder (as last read; until then, by its name).
    private func isSingle(_ folder: Folder) -> Bool { singles?.contains(folder.id) ?? (URL(fileURLWithPath: folder.path).pathExtension != "") }

    /// The folders, and the clips put in one by one.
    var folderItems: [Folder] { folders.filter { !isSingle($0) } }
    var clipItems: [Folder] { folders.filter { isSingle($0) } }

    var allVideos: [String] { folders.flatMap { videos[$0.id] ?? [] } }
    var allPhotos: [String] { folders.flatMap { photos[$0.id] ?? [] } }

    /// Starts looking at the folders (at launch, and when Search opens).
    func start() {
        for folder in folders where watchers[folder.id] == nil { watch(folder); scan(folder) }
    }

    /// A folder or a clip (one already in, or in a folder that is, isn't added twice).
    @discardableResult
    func add(_ url: URL) -> Folder? {
        let path = url.standardizedFileURL.path
        if let known = folders.first(where: { $0.path == path }) { return known }
        if let inside = folder(containing: path), !inside.isFile { return inside }
        let folder = Folder(path: path)
        folders.append(folder)
        save()
        watch(folder)
        scan(folder)
        return folder
    }

    func remove(_ id: UUID) {
        folders.removeAll { $0.id == id }
        videos[id] = nil
        photos[id] = nil
        watchers[id] = nil
        save()
    }

    private func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(folders), forKey: Self.key)
    }

    /// The folder a file is in, if it's in one of them.
    func folder(containing path: String) -> Folder? {
        folders.first { $0.path == path || path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
    }

    // MARK: - Looking through

    func scan(_ folder: Folder) {
        guard folder.isThere, !scanning.contains(folder.id) else { return }
        scanning.insert(folder.id)
        let root = folder.url, single = folder.isFile
        Task {
            let (found, pictures) = await Task.detached(priority: .utility) { single ? ([root.path], []) : Self.media(in: root) }.value
            videos[folder.id] = found
            photos[folder.id] = pictures
            scanning.remove(folder.id)
            index(videos: found, photos: pictures)
        }
    }

    /// Indexes what isn't yet: the shots in each video, what's said (when automatic transcripts
    /// are on), and what's in each photo.
    private func index(videos: [String], photos: [String]) {
        let urls = videos.map { URL(fileURLWithPath: $0) }
        VisualIndexer.shared.reload()
        VisualIndexer.shared.enqueue(urls.filter { Converting.isVideo($0) && !VisualIndex.isIndexed($0) })
        AppDelegate.shared?.ai.imported(urls)
        PhotoIndex.shared.enqueue(photos)
    }

    nonisolated private static func media(in root: URL) -> ([String], [String]) {
        var videos: [String] = [], photos: [String] = []
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return ([], []) }
        for case let file as URL in walker {
            guard (try? file.resourceValues(forKeys: Set(keys)).isRegularFile) == true,
                  let type = UTType(filenameExtension: file.pathExtension) else { continue }
            if type.conforms(to: .movie) || type.conforms(to: .audio) { videos.append(file.path) }
            else if type.conforms(to: .image) { photos.append(file.path) }
        }
        return (videos, photos)
    }

    // MARK: - Watching

    private func watch(_ folder: Folder) {
        guard folder.isThere, !folder.isFile else { return }
        watchers[folder.id] = FolderWatcher(path: folder.path) { [weak self] in
            Task { @MainActor in self?.changed(folder.id) }
        }
    }

    /// Something changed in a folder: looked through again once things settle (a copy in
    /// progress sends many changes).
    private func changed(_ id: UUID) {
        pending[id]?.cancel()
        pending[id] = Task {
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let folder = folders.first(where: { $0.id == id }) else { return }
            scan(folder)
        }
    }
}

/// Calls back when anything changes in a folder or the folders in it (FSEvents).
final class FolderWatcher {
    private var stream: FSEventStreamRef?
    private let changed: () -> Void

    init(path: String, changed: @escaping () -> Void) {
        self.changed = changed
        var context = FSEventStreamContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(), retain: nil, release: nil, copyDescription: nil)
        let callback: FSEventStreamCallback = { _, info, _, _, _, _ in
            guard let info else { return }
            Unmanaged<FolderWatcher>.fromOpaque(info).takeUnretainedValue().changed()
        }
        stream = FSEventStreamCreate(nil, callback, &context, [path] as CFArray, FSEventStreamEventId(kFSEventStreamEventIdSinceNow), 2,
                                     FSEventStreamCreateFlags(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagIgnoreSelf))
        if let stream {
            FSEventStreamSetDispatchQueue(stream, DispatchQueue.global(qos: .utility))
            FSEventStreamStart(stream)
        }
    }

    deinit {
        if let stream {
            FSEventStreamStop(stream)
            FSEventStreamInvalidate(stream)
            FSEventStreamRelease(stream)
        }
    }
}
