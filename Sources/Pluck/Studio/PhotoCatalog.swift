import Foundation
import UniformTypeIdentifiers

struct PhotoRecord: Codable, Hashable {
    enum Flag: String, Codable { case none, pick, reject }

    var rating = 0
    var flag = Flag.none
    /// A colour label's name ("red", "green"…), like in Lightroom.
    var label: String?
    var adjust = PhotoAdjustments()
    var filmOn = false
    var film = FilmSettings()
    var edited: Date?
    /// Noise taken out before developing (0: none, else the strength in %), by AI or not.
    var denoise = 0
    var denoiseAI = false
    /// Looks kept along the way, to go back to.
    var snapshots: [PhotoSnapshot] = []

    var isEdited: Bool { !adjust.isDefault || filmOn || denoise > 0 }

    /// The denoised file's strength key (the AI's counts from 1000).
    var denoiseKey: Int { denoise > 0 && denoiseAI ? 1000 + denoise : denoise }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        rating = try c.decodeIfPresent(Int.self, forKey: .rating) ?? 0
        flag = try c.decodeIfPresent(Flag.self, forKey: .flag) ?? .none
        label = try c.decodeIfPresent(String.self, forKey: .label)
        adjust = try c.decodeIfPresent(PhotoAdjustments.self, forKey: .adjust) ?? PhotoAdjustments()
        filmOn = try c.decodeIfPresent(Bool.self, forKey: .filmOn) ?? false
        film = try c.decodeIfPresent(FilmSettings.self, forKey: .film) ?? FilmSettings()
        edited = try c.decodeIfPresent(Date.self, forKey: .edited)
        denoise = try c.decodeIfPresent(Int.self, forKey: .denoise) ?? 0
        denoiseAI = try c.decodeIfPresent(Bool.self, forKey: .denoiseAI) ?? false
        snapshots = try c.decodeIfPresent([PhotoSnapshot].self, forKey: .snapshots) ?? []
    }
}

/// A look kept to go back to: the adjustments and film at one moment.
struct PhotoSnapshot: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var date = Date.now
    var adjust: PhotoAdjustments
    var filmOn: Bool
    var film: FilmSettings
}

struct PhotoAlbum: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var paths: [String] = []
    var created = Date.now
    /// The folder it's filed in (nil: at the top).
    var folder: UUID?
}

/// A folder of albums, to keep them in order.
struct AlbumFolder: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
}

/// Saved adjustments and film, to give other photos the same look.
struct PhotoPreset: Codable, Identifiable, Hashable {
    var id = UUID()
    var name: String
    var adjust: PhotoAdjustments
    var filmOn: Bool
    var film: FilmSettings
}

/// Every photo Pluck knows: their ratings, flags, labels and edits, and the albums they're in.
/// Kept in Pluck's folder; the photos themselves are never changed.
@MainActor
@Observable
final class PhotoCatalog {
    static let shared = PhotoCatalog()

    enum Source: Hashable {
        case all, picks, rejects, fiveStars, edited, album(UUID), folder(UUID)

        /// As text, to remember which one was open.
        var key: String {
            switch self {
            case .all: "all"
            case .picks: "picks"
            case .rejects: "rejects"
            case .fiveStars: "fiveStars"
            case .edited: "edited"
            case .album(let id): "album:\(id.uuidString)"
            case .folder(let id): "folder:\(id.uuidString)"
            }
        }

        init(key: String) {
            let parts = key.split(separator: ":", maxSplits: 1).map(String.init)
            switch parts.first {
            case "picks": self = .picks
            case "rejects": self = .rejects
            case "fiveStars": self = .fiveStars
            case "edited": self = .edited
            case "album": self = parts.count > 1 ? UUID(uuidString: parts[1]).map(Source.album) ?? .all : .all
            case "folder": self = parts.count > 1 ? UUID(uuidString: parts[1]).map(Source.folder) ?? .all : .all
            default: self = .all
            }
        }
    }

    private(set) var records: [String: PhotoRecord] = [:]
    private(set) var albums: [PhotoAlbum] = []
    private(set) var folders: [AlbumFolder] = []
    private(set) var presets: [PhotoPreset] = []
    @ObservationIgnored private var saveScheduled = false

    private struct Saved: Codable {
        var records: [String: PhotoRecord]
        var albums: [PhotoAlbum]
        var folders: [AlbumFolder]?
        var presets: [PhotoPreset]?
    }

    nonisolated private static var file: URL {
        // Tests keep their own catalogue.
        if let test = UserDefaults.standard.string(forKey: "PluckScreenshotCatalog") { return URL(fileURLWithPath: test) }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Photos/catalog.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            records = saved.records
            albums = saved.albums
            folders = saved.folders ?? []
            presets = saved.presets ?? []
        }
    }

    func record(_ path: String) -> PhotoRecord { records[path] ?? PhotoRecord() }

    func update(_ paths: [String], _ change: (inout PhotoRecord) -> Void) {
        var before: [String: PhotoRecord?] = [:]
        for path in paths {
            before[path] = records[path]
            var record = records[path] ?? PhotoRecord()
            change(&record)
            // A RAW keeps the decoder it was first edited with, so it looks the same after macOS updates.
            if record.adjust.rawDecoder == nil, !record.adjust.isDefault {
                record.adjust.rawDecoder = PhotoRender.currentDecoder(path)
            }
            records[path] = record
        }
        remember(before)
        changed(paths)
    }

    // MARK: - Undo

    /// One change: the photos' records before and after it.
    private struct Step {
        var before: [String: PhotoRecord?]
        var after: [String: PhotoRecord?]
    }

    @ObservationIgnored private var undoSteps: [Step] = []
    @ObservationIgnored private var redoSteps: [Step] = []
    @ObservationIgnored private var lastStep = Date.distantPast
    private(set) var canUndo = false
    private(set) var canRedo = false

    /// Keeps the change to undo it. A slider's drag (the same photos, changes close together)
    /// is one step.
    private func remember(_ before: [String: PhotoRecord?]) {
        let after = Dictionary(uniqueKeysWithValues: before.keys.map { ($0, records[$0]) })
        if let last = undoSteps.last, Set(last.before.keys) == Set(before.keys), Date.now.timeIntervalSince(lastStep) < 0.6 {
            undoSteps[undoSteps.count - 1].after = after
        } else {
            undoSteps.append(Step(before: before, after: after))
            if undoSteps.count > 300 { undoSteps.removeFirst() }
        }
        lastStep = .now
        redoSteps = []
        canUndo = true
        canRedo = false
    }

    /// Takes back the last change; the photos it touched.
    @discardableResult
    func undo() -> [String] {
        guard let step = undoSteps.popLast() else { return [] }
        apply(step.before)
        redoSteps.append(step)
        lastStep = .distantPast
        canUndo = !undoSteps.isEmpty
        canRedo = true
        return Array(step.before.keys)
    }

    @discardableResult
    func redo() -> [String] {
        guard let step = redoSteps.popLast() else { return [] }
        apply(step.after)
        undoSteps.append(step)
        lastStep = .distantPast
        canUndo = true
        canRedo = !redoSteps.isEmpty
        return Array(step.after.keys)
    }

    private func apply(_ state: [String: PhotoRecord?]) {
        for (path, record) in state { records[path] = record }
        changed(Array(state.keys))
    }

    // MARK: - Snapshots

    func takeSnapshot(of path: String) {
        update([path]) { record in
            let name = Date.now.formatted(date: .abbreviated, time: .shortened)
            record.snapshots.append(PhotoSnapshot(name: name, adjust: record.adjust, filmOn: record.filmOn, film: record.film))
        }
    }

    func restore(_ snapshot: PhotoSnapshot, on path: String) {
        update([path]) { record in
            record.adjust = snapshot.adjust
            record.filmOn = snapshot.filmOn
            record.film = snapshot.film
            record.edited = .now
        }
    }

    func deleteSnapshot(_ id: UUID, of path: String) {
        update([path]) { $0.snapshots.removeAll { $0.id == id } }
    }

    // MARK: - Sidecars

    @ObservationIgnored private var sidecarsWaiting: Set<String> = []
    @ObservationIgnored private var sidecarsScheduled = false
    @ObservationIgnored private var sidecarsRead: Set<String> = []

    /// Whether ratings, labels and edits go into XMP sidecars next to the photos (Settings).
    static var writesSidecars: Bool { UserDefaults.standard.bool(forKey: "photoWriteXMP") }

    /// After any change: saved, and the sidecars written (a moment later, in the background).
    private func changed(_ paths: [String]) {
        scheduleSave()
        guard Self.writesSidecars else { return }
        sidecarsWaiting.formUnion(paths)
        guard !sidecarsScheduled else { return }
        sidecarsScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            sidecarsScheduled = false
            let waiting = sidecarsWaiting.map { ($0, record($0)) }
            sidecarsWaiting = []
            await Task.detached(priority: .utility) {
                // A photo in a place Pluck can't write to keeps going without one.
                for (path, record) in waiting { try? PhotoXMP.write(path, record: record) }
            }.value
        }
    }

    /// Writes the sidecars of every photo with something to say (when writing is turned on).
    func writeAllSidecars() {
        changed(records.filter { $0.value.rating > 0 || $0.value.flag != .none || $0.value.label != nil || $0.value.isEdited }.map(\.key))
    }

    /// Ratings, labels and flags other apps wrote (or Pluck's own edit from a sidecar), for
    /// photos Pluck knows nothing about yet. In the background; once per photo per launch.
    func readSidecars(_ paths: [String]) {
        let unknown = paths.filter { records[$0] == nil && !sidecarsRead.contains($0) }
        guard !unknown.isEmpty else { return }
        sidecarsRead.formUnion(unknown)
        Task {
            let found = await Task.detached(priority: .utility) {
                unknown.compactMap { path in PhotoXMP.read(path).map { (path, $0) } }
            }.value
            guard !found.isEmpty else { return }
            for (path, metadata) in found where records[path] == nil {
                var record = metadata.record ?? PhotoRecord()
                if let rating = metadata.rating { record.rating = rating }
                if metadata.label != nil { record.label = metadata.label }
                if metadata.rejected { record.flag = .reject }
                records[path] = record
            }
            scheduleSave()
        }
    }

    /// Every photo in the albums and the watched folders.
    var allPhotos: [String] {
        var seen: Set<String> = []
        return (albums.flatMap(\.paths) + FootageFolders.shared.allPhotos).filter { seen.insert($0).inserted }
    }

    func photos(in source: Source) -> [String] {
        switch source {
        case .all: allPhotos
        case .picks: allPhotos.filter { record($0).flag == .pick }
        case .rejects: allPhotos.filter { record($0).flag == .reject }
        case .fiveStars: allPhotos.filter { record($0).rating == 5 }
        case .edited: allPhotos.filter { record($0).isEdited }.sorted { (record($0).edited ?? .distantPast) > (record($1).edited ?? .distantPast) }
        case .album(let id): albums.first { $0.id == id }?.paths ?? []
        case .folder(let id): FootageFolders.shared.photos[id] ?? []
        }
    }

    // MARK: - Albums

    @discardableResult
    func newAlbum(named name: String, with paths: [String] = []) -> PhotoAlbum {
        let album = PhotoAlbum(name: name, paths: paths)
        albums.append(album)
        scheduleSave()
        PhotoIndex.shared.enqueue(paths)
        readSidecars(paths)
        return album
    }

    func add(_ paths: [String], to id: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let existing = Set(albums[index].paths)
        albums[index].paths += paths.filter { !existing.contains($0) }
        scheduleSave()
        PhotoIndex.shared.enqueue(paths)
        readSidecars(paths)
    }

    func remove(_ paths: [String], from id: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let gone = Set(paths)
        albums[index].paths.removeAll { gone.contains($0) }
        scheduleSave()
    }

    func rename(_ id: UUID, to name: String) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index].name = name
        scheduleSave()
    }

    func deleteAlbum(_ id: UUID) {
        albums.removeAll { $0.id == id }
        scheduleSave()
    }

    // MARK: - Folders of albums

    @discardableResult
    func newFolder(named name: String) -> AlbumFolder {
        let folder = AlbumFolder(name: name)
        folders.append(folder)
        scheduleSave()
        return folder
    }

    func renameFolder(_ id: UUID, to name: String) {
        guard let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = name
        scheduleSave()
    }

    /// Removes the folder; its albums move to the top.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for index in albums.indices where albums[index].folder == id { albums[index].folder = nil }
        scheduleSave()
    }

    func move(album id: UUID, to folder: UUID?) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        albums[index].folder = folder
        scheduleSave()
    }

    // MARK: - Presets

    func savePreset(named name: String, from record: PhotoRecord) {
        presets.append(PhotoPreset(name: name, adjust: record.adjust, filmOn: record.filmOn, film: record.film))
        presets.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        scheduleSave()
    }

    func deletePreset(_ id: UUID) {
        presets.removeAll { $0.id == id }
        scheduleSave()
    }

    /// Photos in these files and folders (folders are looked through, with their folders).
    nonisolated static func photos(in urls: [URL]) -> [String] {
        var found: [String] = []
        for url in urls {
            var isFolder: ObjCBool = false
            FileManager.default.fileExists(atPath: url.path, isDirectory: &isFolder)
            if isFolder.boolValue {
                if let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                    for case let file as URL in walker where isPhoto(file) { found.append(file.path) }
                }
            } else if isPhoto(url) {
                found.append(url.path)
            }
        }
        return found.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    nonisolated static func isPhoto(_ url: URL) -> Bool {
        guard let type = UTType(filenameExtension: url.pathExtension) else { return false }
        return type.conforms(to: .image) && !type.conforms(to: .gif)
    }

    // MARK: - Saving

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(1))
            saveScheduled = false
            let saved = Saved(records: records, albums: albums, folders: folders, presets: presets)
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(saved).write(to: Self.file, options: .atomic)
            }.value
        }
    }
}
