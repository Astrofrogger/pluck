import Foundation

/// A sync kept beside its media (a hidden ".pluck-sync.json" in the folder all its clips are in), so
/// dropping that folder again reopens it, and cards added later sync against what's placed.
/// Paths are kept relative to that folder: the same drive or share mounted elsewhere still opens.
/// (Fields added to SyncClip/SyncCamera later must be optional, or saves made before them won't open.)
struct SyncSave: Codable {
    var version = 1
    var cameras: [SyncCamera]
    var audioFirst: Bool?
    var shownTimecode: Bool?
}

extension CameraSync {
    static let saveName = ".pluck-sync.json"

    /// The folder every clip is in (deepest shared), when that's a real folder (not "/" or /Volumes: clips on two drives aren't kept).
    static func saveFolder(_ cameras: [SyncCamera]) -> URL? {
        let folders = cameras.flatMap(\.clips).map { $0.file.deletingLastPathComponent().standardizedFileURL.pathComponents }
        guard var shared = folders.first else { return nil }
        for parts in folders.dropFirst() {
            var n = 0
            while n < min(shared.count, parts.count), shared[n] == parts[n] { n += 1 }
            shared = Array(shared.prefix(n))
        }
        guard shared.count >= 3 || (shared.count == 2 && shared[1] != "Volumes") else { return nil }
        return URL(fileURLWithPath: NSString.path(withComponents: shared), isDirectory: true)
    }

    static func save(_ save: SyncSave) throws {
        guard let folder = saveFolder(save.cameras) else { return }
        var save = save
        let prefix = folder.path.hasSuffix("/") ? folder.path : folder.path + "/"
        func relative(_ path: String) -> String { path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : path }
        for c in save.cameras.indices {
            for i in save.cameras[c].clips.indices {
                save.cameras[c].clips[i].path = relative(save.cameras[c].clips[i].path)
                save.cameras[c].clips[i].proxy = save.cameras[c].clips[i].proxy.map(relative)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(save).write(to: folder.appendingPathComponent(saveName), options: .atomic)
    }

    /// The sync saved in `folder`, its clips that are still there (with their full paths).
    static func load(_ folder: URL) -> SyncSave? {
        guard let data = try? Data(contentsOf: folder.appendingPathComponent(saveName)), var save = try? JSONDecoder().decode(SyncSave.self, from: data) else { return nil }
        let fm = FileManager.default
        func full(_ path: String) -> String { path.hasPrefix("/") ? path : folder.appendingPathComponent(path).standardizedFileURL.path }
        for c in save.cameras.indices {
            for i in save.cameras[c].clips.indices {
                save.cameras[c].clips[i].path = full(save.cameras[c].clips[i].path)
                save.cameras[c].clips[i].proxy = save.cameras[c].clips[i].proxy.map(full).flatMap { fm.fileExists(atPath: $0) ? $0 : nil }
            }
            save.cameras[c].clips.removeAll { !fm.fileExists(atPath: $0.path) }
        }
        save.cameras.removeAll { $0.clips.isEmpty }
        return save.cameras.isEmpty ? nil : save
    }

    /// A sync saved with what was dropped: in a dropped folder, or a folder of the found clips up to the one they share
    /// (a first card synced alone saved in its own folder); the one with the most clips.
    static func savedSync(dropped: [URL], found: [URL]) -> SyncSave? {
        var places = Set(dropped.filter(\.hasDirectoryPath).map { $0.standardizedFileURL.path })
        if let shared = saveFolder([SyncCamera(name: "", key: "", clips: found.map { SyncClip(path: $0.standardizedFileURL.path) })])?.path {
            for folder in Set(found.map { $0.deletingLastPathComponent().standardizedFileURL.path }) {
                var at = folder
                while at.hasPrefix(shared), !places.contains(at) {
                    places.insert(at)
                    at = (at as NSString).deletingLastPathComponent
                }
            }
        }
        return places.filter { FileManager.default.fileExists(atPath: ($0 as NSString).appendingPathComponent(saveName)) }
            .compactMap { load(URL(fileURLWithPath: $0, isDirectory: true)) }
            .max { $0.cameras.flatMap(\.clips).count < $1.cameras.flatMap(\.clips).count }
    }
}
