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
    /// Noise taken out before developing (0: none, else the strength in %).
    var denoise = 0

    var isEdited: Bool { !adjust.isDefault || filmOn || denoise > 0 }

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
    }
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
        for path in paths {
            var record = records[path] ?? PhotoRecord()
            change(&record)
            records[path] = record
        }
        scheduleSave()
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
        return album
    }

    func add(_ paths: [String], to id: UUID) {
        guard let index = albums.firstIndex(where: { $0.id == id }) else { return }
        let existing = Set(albums[index].paths)
        albums[index].paths += paths.filter { !existing.contains($0) }
        scheduleSave()
        PhotoIndex.shared.enqueue(paths)
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
