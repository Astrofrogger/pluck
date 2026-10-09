import Foundation
import Observation
import UniformTypeIdentifiers

/// Everything Pluck has saved, kept for good (the download list only keeps the latest 200):
/// downloads, conversions and files from this Mac, with tags. Stored in
/// Application Support/Pluck/library.json.
@MainActor
@Observable
final class LibraryStore {
    static let shared = LibraryStore()

    struct Entry: Codable, Identifiable, Hashable {
        /// The file's path, which is what makes an entry unique.
        var id: String { path }
        var path: String
        var title: String
        var uploader: String?
        /// The page it came from (nil for files from this Mac).
        var source: String?
        var duration: Double?
        var size: Int64?
        var thumbnail: URL?
        var added: Date
        var tags: [String] = []
        var transcriptID: String?

        var file: URL { URL(fileURLWithPath: path) }

        enum Kind: String { case video, audio, photo, other }

        /// From the file name alone, so filtering a big library stays quick (folders of
        /// chapters have no extension and count as other).
        var kind: Kind {
            guard let type = UTType(filenameExtension: file.pathExtension) else { return .other }
            if type.conforms(to: .movie) { return .video }
            if type.conforms(to: .audio) { return .audio }
            if type.conforms(to: .image) { return .photo }
            return .other
        }

        /// "YouTube", "Reddit"…, from the page it came from.
        var site: String? {
            guard let source, let host = URL(string: source)?.host?.lowercased(), !host.isEmpty else { return nil }
            let parts = host.split(separator: ".").filter { !["www", "m", "old", "music", "v", "i"].contains($0) }
            guard parts.count >= 2 else { return host }
            let name = String(parts[parts.count - 2])
            let known = ["youtube": "YouTube", "youtu": "YouTube", "redd": "Reddit", "reddit": "Reddit", "tiktok": "TikTok",
                         "instagram": "Instagram", "vimeo": "Vimeo", "soundcloud": "SoundCloud", "x": "X", "twitter": "X",
                         "facebook": "Facebook", "twitch": "Twitch", "bandcamp": "Bandcamp", "dailymotion": "Dailymotion",
                         "spotify": "Spotify", "apple": "Apple Music"]
            return known[name] ?? name.prefix(1).uppercased() + name.dropFirst()
        }
    }

    private(set) var entries: [Entry] = []
    @ObservationIgnored private var saveScheduled = false

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/library.json")
    }

    private init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let data = try? Data(contentsOf: Self.fileURL), let saved = try? decoder.decode([Entry].self, from: data) {
            entries = saved
        }
    }

    /// Adds finished items from the download list (or updates them), called whenever the list is saved.
    func record(_ items: [DownloadItem]) {
        var changed = false
        var index = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($1.path, $0) })
        for item in items where item.state == .finished {
            guard let file = item.fileURL else { continue }
            let source = item.conversion == nil && !item.isLocalFile ? item.url : nil
            if let position = index[file.path] {
                var entry = entries[position]
                let before = entry
                entry.title = item.title
                entry.uploader = item.uploader ?? entry.uploader
                entry.duration = item.duration ?? entry.duration
                entry.size = item.fileSize ?? entry.size
                entry.thumbnail = item.thumbnail ?? entry.thumbnail
                entry.transcriptID = item.transcriptID ?? entry.transcriptID
                if entry != before { entries[position] = entry; changed = true }
            } else {
                entries.append(Entry(path: file.path, title: item.title, uploader: item.uploader, source: source,
                                     duration: item.duration, size: item.fileSize, thumbnail: item.thumbnail,
                                     added: item.finishedAt ?? .now, transcriptID: item.transcriptID))
                index[file.path] = entries.count - 1
                changed = true
            }
        }
        if changed { scheduleSave() }
    }

    func setTags(_ tags: [String], for entry: Entry) {
        guard let position = entries.firstIndex(where: { $0.path == entry.path }) else { return }
        entries[position].tags = tags
        scheduleSave()
    }

    func remove(_ removed: [Entry]) {
        let paths = Set(removed.map(\.path))
        entries.removeAll { paths.contains($0.path) }
        scheduleSave()
    }

    var allTags: [String] {
        Array(Set(entries.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var sites: [String] {
        Array(Set(entries.compactMap(\.site))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Entries that look like the same thing saved more than once: the same page, or the same
    /// size and length. Grouped together, newest first within a group.
    var duplicates: [Entry] {
        var groups: [String: [Entry]] = [:]
        for entry in entries where FileManager.default.fileExists(atPath: entry.path) {
            let key: String
            if let source = entry.source { key = "page:" + source }
            else if let size = entry.size, size > 0 { key = "size:\(size):\(Int((entry.duration ?? 0).rounded()))" }
            else { continue }
            groups[key, default: []].append(entry)
        }
        return groups.values.filter { $0.count > 1 }
            .sorted { ($0.first?.title ?? "") < ($1.first?.title ?? "") }
            .flatMap { $0.sorted { $0.added > $1.added } }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            try? FileManager.default.createDirectory(at: Self.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? encoder.encode(self.entries).write(to: Self.fileURL, options: .atomic)
        }
    }
}
