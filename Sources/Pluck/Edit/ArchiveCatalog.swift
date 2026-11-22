import CryptoKit
import Foundation

/// Archive's catalogue: per project a hidden manifest beside its masters (`<project>/.pluck-archive/manifest.json`)
/// with every archived clip (its original's path, size, hash, codec, picture size, frame rate, start timecode, reel,
/// sound channels, camera; where the original went: the folder to delete, its second copy, deleted) and one small
/// thumbnail from its master. Kept up to date by whichever Mac archives there (entries by original, others kept), so
/// a search finds every project's clips on the shares that are mounted.
enum ArchiveCatalog {
    static let folderName = ".pluck-archive"

    struct Clip: Codable, Hashable, Identifiable, Sendable {
        var id: String { original }
        var original: String
        var size: Int64
        /// The original's xxHash64 (from its second copy; nil: none made) and the master's.
        var hash: String?
        var masterHash: String?
        var master: String?
        var codec: String
        var width: Int
        var height: Int
        var fps: Double
        var timecode: String?
        var reel: String?
        var channels: Int
        var camera: String?
        var modified: Date
        var client: String
        var project: String
        /// Its project's folder (where the manifest and thumbnails are).
        var folder: String
        /// "to delete", "deleted", "in place" (a run into another folder), "restored".
        var status: String
        var movedTo: String?
        var copy: String?
        var copyTarget: String?
        var thumbnail: String?
        var updated: Date
    }

    static func folder(_ project: String) -> URL { URL(fileURLWithPath: project).appendingPathComponent(folderName, isDirectory: true) }
    static func manifest(_ project: String) -> URL { folder(project).appendingPathComponent("manifest.json") }

    static func read(_ project: String) -> [Clip] { load(project) ?? [] }

    /// The project's manifest ([]: none yet; nil: one is there but can't be read, so it's never written anew).
    static func load(_ project: String) -> [Clip]? {
        guard let data = try? Data(contentsOf: manifest(project)) else { return FileManager.default.fileExists(atPath: manifest(project).path) ? nil : [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode([Clip].self, from: data)
    }

    /// Where an original is now (looked at on the drive).
    static func place(_ file: ShrinkFolders.File) -> String {
        if file.state == .restored { return "restored" }
        guard let moved = file.moved else { return "in place" }
        if FileManager.default.fileExists(atPath: moved) { return "to delete" }
        // (Its folder to delete there but the original gone: deleted by the owner. Not mounted: as it was.)
        return ShrinkFolders.holdingFolder(of: moved).map { FileManager.default.fileExists(atPath: $0.path) } == true ? "deleted" : "to delete"
    }

    static func thumbName(_ original: String) -> String {
        SHA256.hash(data: Data(original.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    /// Each project's manifest with these files (done or put back) written anew, the entries of other runs and Macs kept;
    /// a thumbnail made from each master that hasn't one. A project held, one not mounted, or one whose manifest can't be read is left.
    static func update(_ files: [ShrinkFolders.File], ffmpeg: String?) {
        let fm = FileManager.default
        for (project, list) in Dictionary(grouping: files.filter { [.done, .restored].contains($0.state) }, by: { $0.project.isEmpty ? $0.folder : $0.project }) {
            guard fm.fileExists(atPath: project), ArchiveProject.heldNow(project) == nil, let known = load(project) else { continue }
            let place = folder(project)
            try? fm.createDirectory(at: place, withIntermediateDirectories: true)
            var clips = Dictionary(known.map { ($0.original, $0) }, uniquingKeysWith: { $1 })
            var changed = !fm.fileExists(atPath: manifest(project).path)
            for file in list {
                let thumb = thumbName(file.path)
                let thumbURL = place.appendingPathComponent(thumb)
                if !fm.fileExists(atPath: thumbURL.path), let ffmpeg, let master = file.master, file.state == .done, fm.fileExists(atPath: master) {
                    ProjectArchive.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-ss", String(format: "%.2f", max(file.seconds / 2, 0)), "-i", master,
                                                "-frames:v", "1", "-vf", "scale=240:-2", "-q:v", "5", thumbURL.path])
                }
                var clip = Clip(original: file.path, size: file.size, hash: file.copied?.hashes[(file.path as NSString).lastPathComponent],
                                        masterHash: file.masterHash, master: file.master, codec: file.codec, width: file.width, height: file.height,
                                        fps: file.fps, timecode: file.timecode, reel: file.reel, channels: file.channels, camera: file.camera,
                                        modified: file.modified, client: file.client, project: file.projectName, folder: project, status: Self.place(file),
                                        movedTo: file.moved, copy: file.copied.map { ($0.folder as NSString).appendingPathComponent((file.path as NSString).lastPathComponent) },
                                        copyTarget: file.copied?.target, thumbnail: fm.fileExists(atPath: thumbURL.path) ? thumb : nil, updated: .now)
                // (Written only when something about it changed.)
                if var old = clips[file.path] { old.updated = clip.updated; if old == clip { continue } }
                clip.updated = .now
                clips[file.path] = clip
                changed = true
            }
            guard changed else { continue }
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(clips.values.sorted { $0.original < $1.original }) else { continue }
            let saving = place.appendingPathComponent("manifest.json.\(UUID().uuidString.prefix(8)).saving")
            if (try? data.write(to: saving)) != nil, Darwin.rename(saving.path, manifest(project).path) != 0 { unlink(saving.path) }
        }
    }

    /// The text a clip is found by: its name and path, client and project, camera, codec, size, rate, reel, timecode, year.
    static func words(_ clip: Clip) -> String {
        let year = Calendar.current.component(.year, from: clip.modified)
        return [clip.original, clip.client, clip.project, clip.camera ?? "", clip.codec, "\(clip.width)x\(clip.height)", clip.height >= 2000 ? "4k" : "",
                String(format: "%g", (clip.fps * 100).rounded() / 100), clip.reel ?? "", clip.timecode ?? "", "\(year)", clip.status]
            .joined(separator: " ").lowercased()
    }

    /// Every word of the query in a clip's text (any order). Several words narrow it ("drone 2024").
    static func matches(_ clip: Clip, _ query: String) -> Bool {
        let text = words(clip)
        let wanted = query.lowercased().split(whereSeparator: \.isWhitespace)
        return !wanted.isEmpty && wanted.allSatisfy { text.contains($0) }
    }

    /// The clips of these projects' manifests (those mounted) that match, newest first.
    static func search(_ query: String, projects: [String], limit: Int = 300) -> [Clip] {
        var found: [Clip] = []
        for project in Set(projects) where FileManager.default.fileExists(atPath: manifest(project).path) {
            found += read(project).filter { matches($0, query) }
        }
        return Array(found.sorted { $0.modified > $1.modified }.prefix(limit))
    }
}
