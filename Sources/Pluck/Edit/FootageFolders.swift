import CoreServices
import Foundation
import UniformTypeIdentifiers

/// Folders Pluck keeps an eye on: every video, song and photo in them (and in their folders) is
/// indexed so Search finds it, and new files are picked up as they arrive. Search can look in
/// one of them only, like a project.
@MainActor
@Observable
final class FootageFolders {
    static let shared = FootageFolders()

    struct Folder: Codable, Identifiable, Hashable {
        var id = UUID()
        var path: String
        var name: String { URL(fileURLWithPath: path).lastPathComponent }
        var url: URL { URL(fileURLWithPath: path, isDirectory: true) }
        /// The drive it's on is plugged in.
        var isThere: Bool { FileManager.default.fileExists(atPath: path) }
    }

    private(set) var folders: [Folder] = []
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
    }

    var allVideos: [String] { folders.flatMap { videos[$0.id] ?? [] } }
    var allPhotos: [String] { folders.flatMap { photos[$0.id] ?? [] } }

    /// Starts looking at the folders (at launch, and when Search opens).
    func start() {
        for folder in folders where watchers[folder.id] == nil { watch(folder); scan(folder) }
    }

    func add(_ url: URL) {
        let path = url.standardizedFileURL.path
        guard !folders.contains(where: { $0.path == path }) else { return }
        let folder = Folder(path: path)
        folders.append(folder)
        save()
        watch(folder)
        scan(folder)
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
        folders.first { path.hasPrefix($0.path.hasSuffix("/") ? $0.path : $0.path + "/") }
    }

    // MARK: - Looking through

    func scan(_ folder: Folder) {
        guard folder.isThere, !scanning.contains(folder.id) else { return }
        scanning.insert(folder.id)
        let root = folder.url
        Task {
            let (found, pictures) = await Task.detached(priority: .utility) { Self.media(in: root) }.value
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
        guard folder.isThere else { return }
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
