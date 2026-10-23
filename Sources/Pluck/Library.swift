import AppKit
import Foundation
import Observation
import SwiftUI
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

    private(set) var entries: [Entry] = [] {
        didSet { changed() }
    }
    /// Goes up whenever the entries change (what the views keep worked-out lists by).
    private(set) var version = 0
    /// Entries saved more than once (worked out off the main thread after a change: it looks
    /// at every file).
    private(set) var duplicates: [Entry] = []
    @ObservationIgnored private var duplicatesTask: Task<Void, Never>?
    @ObservationIgnored private var countsCache: (version: Int, counts: Counts)?
    @ObservationIgnored private var saveScheduled = false
    /// Files taken out of the Library, and when: the download list doesn't put them back (only
    /// downloading them again does).
    @ObservationIgnored private var removedPaths: [String: Date] = [:]

    private static var removedURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/library-removed.json")
    }

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
        if let data = try? Data(contentsOf: Self.removedURL), let saved = try? decoder.decode([String: Date].self, from: data) {
            removedPaths = saved
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
                // Taken out of the Library (and not downloaded again since), or not there any more.
                if let removed = removedPaths[file.path], (item.finishedAt ?? .distantPast) <= removed { continue }
                guard FileManager.default.fileExists(atPath: file.path) else { continue }
                removedPaths[file.path] = nil
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
        for path in paths { removedPaths[path] = .now }
        scheduleSave()
    }

    var allTags: [String] {
        Array(Set(entries.flatMap(\.tags))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    var sites: [String] {
        Array(Set(entries.compactMap(\.site))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// How many entries of each kind, site and tag (for the sidebar), counted once per change.
    struct Counts {
        var kinds: [Entry.Kind: Int] = [:]
        var sites: [String: Int] = [:]
        var tags: [String: Int] = [:]
        var recent = 0
        var sized = 0
    }

    var counts: Counts {
        if let cache = countsCache, cache.version == version { return cache.counts }
        var counts = Counts()
        let week = Date.now.addingTimeInterval(-7 * 86_400)
        for entry in entries {
            counts.kinds[entry.kind, default: 0] += 1
            if let site = entry.site { counts.sites[site, default: 0] += 1 }
            for tag in entry.tags { counts.tags[tag, default: 0] += 1 }
            if entry.added > week { counts.recent += 1 }
            if (entry.size ?? 0) > 0 { counts.sized += 1 }
        }
        countsCache = (version, counts)
        return counts
    }

    private func changed() {
        version += 1
        duplicatesTask?.cancel()
        let all = entries
        duplicatesTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            let found = await Task.detached(priority: .utility) { Self.findDuplicates(all) }.value
            guard !Task.isCancelled else { return }
            duplicates = found
        }
    }

    /// Entries that look like the same thing saved more than once: the same page, or the same
    /// size and length. Grouped together, newest first within a group.
    nonisolated private static func findDuplicates(_ entries: [Entry]) -> [Entry] {
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
            try? encoder.encode(self.removedPaths).write(to: Self.removedURL, options: .atomic)
        }
    }
}

// MARK: - Missing files

extension LibraryStore {
    /// Forgets the files that are no longer where Pluck saved them, after asking. Files on a
    /// drive that isn't connected aren't missing, only offline: they stay.
    func removeMissingAfterAsking() {
        let all = entries
        Task {
            let (gone, offline) = await Task.detached(priority: .userInitiated) { () -> ([Entry], Int) in
                let absent = all.filter { !FileManager.default.fileExists(atPath: $0.path) }
                let offline = absent.filter { Self.isOnDisconnectedDrive($0.path) }
                return (absent.filter { !Self.isOnDisconnectedDrive($0.path) }, offline.count)
            }.value
            let alert = NSAlert()
            guard !gone.isEmpty else {
                alert.messageText = String(localized: "No Missing Files")
                alert.informativeText = offline > 0
                    ? String(localized: "Every file is where Pluck saved it, or on a drive that isn’t connected.")
                    : String(localized: "Every file is where Pluck saved it.")
                alert.runModal()
                return
            }
            alert.messageText = String(localized: "Remove \(gone.count) missing files from the Library?")
            var text = String(localized: "They’re no longer where Pluck saved them. Nothing is deleted.")
            if offline > 0 { text += " " + String(localized: "\(offline) more are on drives that aren’t connected: they stay.") }
            alert.informativeText = text
            alert.addButton(withTitle: String(localized: "Remove"))
            alert.addButton(withTitle: String(localized: "Cancel"))
            if alert.runModal() == .alertFirstButtonReturn { remove(gone) }
        }
    }

    /// Whether a path is on a drive that isn't connected now (/Volumes/Name/… without the drive).
    nonisolated static func isOnDisconnectedDrive(_ path: String) -> Bool {
        let parts = (path as NSString).standardizingPath.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count >= 2, parts[0] == "Volumes" else { return false }
        let volume = "/Volumes/" + parts[1]
        var info = statfs()
        // The drive's folder is gone, or only a leftover folder on the Mac's own disk.
        guard statfs(volume, &info) == 0 else { return true }
        let mountedAt = withUnsafeBytes(of: info.f_mntonname) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        // (The Mac's own disk is in /Volumes as a link to /.)
        return mountedAt != URL(fileURLWithPath: volume).resolvingSymlinksInPath().path
    }
}

/// File ▸ Remove Missing Files from Library…
struct RemoveMissingCommand: View {
    var body: some View {
        Button("Remove Missing Files from Library…") { LibraryStore.shared.removeMissingAfterAsking() }
    }
}
