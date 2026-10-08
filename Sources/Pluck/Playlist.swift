import Foundation
import Observation

/// One video or track in a playlist the user is picking from.
struct PlaylistEntry: Identifiable, Equatable {
    let id: String
    let url: String
    let title: String
    let subtitle: String?
    let duration: Double?
    let thumbnail: URL?
    /// Set for Spotify albums and playlists, so the download is matched and tagged like a track link.
    var spotify: SpotifyTrack?

    static func == (a: PlaylistEntry, b: PlaylistEntry) -> Bool { a.id == b.id }
}

/// A playlist link waiting for the user to choose what to download.
@MainActor
@Observable
final class PlaylistPick: Identifiable {
    enum Phase: Equatable { case loading, ready, failed(String) }

    let id = UUID()
    let sourceURL: String
    let folder: String
    var options: DownloadOptions

    var phase: Phase = .loading
    var title = String(localized: "Playlist")
    var owner: String?
    var entries: [PlaylistEntry] = []
    var selected: Set<PlaylistEntry.ID> = []
    /// Entries left out because they're private, deleted or otherwise unavailable.
    var hiddenCount = 0

    init(sourceURL: String, folder: String, options: DownloadOptions) {
        self.sourceURL = sourceURL
        self.folder = folder
        self.options = options
    }

    var selectedEntries: [PlaylistEntry] { entries.filter { selected.contains($0.id) } }
    var allSelected: Bool { !entries.isEmpty && selected.count == entries.count }

    func selectAll() { selected = Set(entries.map(\.id)) }
    func selectNone() { selected = [] }

    func toggle(_ entry: PlaylistEntry) {
        if selected.contains(entry.id) { selected.remove(entry.id) } else { selected.insert(entry.id) }
    }
}

enum Playlists {
    /// Links that point at a list rather than one video. Single videos skip the picker entirely,
    /// so they never wait for an extra lookup.
    static func looksLikePlaylist(_ link: String) -> Bool {
        if let spotify = Spotify.parse(link) { return spotify.kind != .track }
        guard let url = URL(string: link), let host = url.host?.lowercased() else { return false }
        let path = url.path.lowercased()
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if host.hasSuffix("youtube.com") || host == "youtu.be" {
            return path.hasPrefix("/playlist") || items.contains { $0.name == "list" && !($0.value ?? "").isEmpty }
        }
        if host.hasSuffix("soundcloud.com") { return path.contains("/sets/") }
        return false
    }

    /// For a video link that also names a playlist (watch?v=…&list=…), the video to start with.
    static func focusedVideoID(in link: String) -> String? {
        guard let url = URL(string: link) else { return nil }
        if url.host?.lowercased() == "youtu.be" { return url.pathComponents.dropFirst().first }
        return URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "v" }?.value
    }

    static let limit = 500

    /// Reads a playlist from yt-dlp's flat listing (titles, lengths and thumbnails, no downloading).
    static func parse(_ data: Data) -> (title: String?, owner: String?, entries: [PlaylistEntry], hidden: Int)? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              json["_type"] as? String == "playlist",
              let raw = json["entries"] as? [[String: Any]] else { return nil }
        var entries: [PlaylistEntry] = []
        var hidden = 0
        for e in raw {
            let title = e["title"] as? String ?? ""
            guard let url = (e["url"] as? String) ?? (e["webpage_url"] as? String),
                  !title.isEmpty, !["[Private video]", "[Deleted video]"].contains(title) else {
                hidden += 1
                continue
            }
            let thumb = ((e["thumbnails"] as? [[String: Any]])?.last?["url"] as? String).flatMap(URL.init)
            entries.append(PlaylistEntry(
                id: (e["id"] as? String) ?? url, url: url, title: title,
                subtitle: (e["channel"] as? String) ?? (e["uploader"] as? String),
                duration: e["duration"] as? Double, thumbnail: thumb))
        }
        return (json["title"] as? String, (json["uploader"] as? String) ?? (json["channel"] as? String), entries, hidden)
    }
}
