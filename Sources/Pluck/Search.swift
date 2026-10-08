import Foundation
import Observation

/// One search result: a YouTube video or a YouTube Music song.
struct SearchResult: Identifiable, Equatable {
    let id: String
    let url: String
    let title: String
    var subtitle: String?
    let duration: Double?
    let views: Int?
    let thumbnail: URL?
}

/// Searching YouTube (videos) or YouTube Music (songs) from the link field.
@MainActor
@Observable
final class SearchSession: Identifiable {
    enum Kind: String, CaseIterable, Identifiable {
        case videos, music
        var id: String { rawValue }
        var label: String {
            switch self {
            case .videos: String(localized: "Videos")
            case .music: String(localized: "Music")
            }
        }
    }

    enum Phase: Equatable { case loading, ready, failed }

    let id = UUID()
    let query: String
    var kind: Kind
    var phase: Phase = .loading
    var results: [SearchResult] = []
    /// Results added to the download list from this search.
    var added: Set<SearchResult.ID> = []

    init(query: String, kind: Kind) {
        self.query = query
        self.kind = kind
    }
}

enum Searching {
    static let count = 15

    /// yt-dlp arguments for a flat search (titles and details only, nothing downloaded).
    static func arguments(query: String, kind: SearchSession.Kind) -> [String] {
        let target: String
        switch kind {
        case .videos:
            target = "ytsearch\(count):\(query)"
        case .music:
            var c = URLComponents(string: "https://music.youtube.com/search")!
            c.queryItems = [URLQueryItem(name: "q", value: query)]
            target = c.url!.absoluteString + "#songs"
        }
        return ["--flat-playlist", "--dump-single-json", "--no-warnings", "--playlist-items", "1:\(count)", "--", target]
    }

    static func parse(_ data: Data) -> [SearchResult] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let entries = json["entries"] as? [[String: Any]] else { return [] }
        return entries.compactMap { e in
            guard let id = e["id"] as? String, let url = e["url"] as? String,
                  let title = e["title"] as? String, !title.isEmpty else { return nil }
            let thumb = ((e["thumbnails"] as? [[String: Any]])?.last?["url"] as? String).flatMap(URL.init)
                ?? URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")
            return SearchResult(id: id, url: url, title: title,
                                subtitle: (e["channel"] as? String) ?? (e["uploader"] as? String),
                                duration: e["duration"] as? Double, views: e["view_count"] as? Int,
                                thumbnail: thumb)
        }
    }

    /// YouTube Music's song search only gives titles; YouTube's public oEmbed adds the artist.
    static func addArtists(to results: [SearchResult]) async -> [SearchResult] {
        await withTaskGroup(of: (Int, String?).self) { group in
            for (index, result) in results.enumerated() where result.subtitle == nil {
                group.addTask {
                    var c = URLComponents(string: "https://www.youtube.com/oembed")!
                    c.queryItems = [URLQueryItem(name: "url", value: "https://www.youtube.com/watch?v=\(result.id)"),
                                    URLQueryItem(name: "format", value: "json")]
                    let request = URLRequest(url: c.url!, timeoutInterval: 6)
                    guard let (data, _) = try? await URLSession.shared.data(for: request),
                          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                          let author = json["author_name"] as? String else { return (index, nil) }
                    // Auto-generated music channels are called "Artist - Topic".
                    let artist = author.hasSuffix(" - Topic") ? String(author.dropLast(8)) : author
                    return (index, artist)
                }
            }
            var updated = results
            for await (index, artist) in group where artist != nil { updated[index].subtitle = artist }
            return updated
        }
    }

    /// "10M views", "1.4K views", using the user's locale.
    static func views(_ count: Int) -> String {
        let formatted = count.formatted(.number.notation(.compactName).precision(.fractionLength(0...1)))
        return String(localized: "\(formatted) views")
    }
}
