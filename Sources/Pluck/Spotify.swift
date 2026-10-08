import Foundation

/// A track read from Spotify's public embed page. Spotify audio is DRM-protected, so the
/// actual audio is matched on YouTube Music and tagged with Spotify's metadata.
struct SpotifyTrack: Sendable, Codable {
    var id: String
    var title: String
    var artists: [String]
    var duration: Double?
    var album: String?
    var cover: URL?

    var url: String { "https://open.spotify.com/track/\(id)" }
}

enum Spotify {
    enum Kind: String { case track, album, playlist }

    struct Link {
        let kind: Kind
        let id: String
    }

    struct Collection {
        let name: String
        let kind: Kind
        let tracks: [SpotifyTrack]
    }

    enum Failure: LocalizedError {
        case unsupported, unreadable

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "Only Spotify track, album and playlist links are supported.")
            case .unreadable: String(localized: "Couldn’t read this Spotify page. It may be private or region-locked.")
            }
        }
    }

    /// Matches open.spotify.com/track/ID, /intl-xx/album/ID, and spotify:playlist:ID.
    static func parse(_ string: String) -> Link? {
        if string.hasPrefix("spotify:") {
            let parts = string.split(separator: ":")
            guard parts.count == 3, let kind = Kind(rawValue: String(parts[1])) else { return nil }
            return Link(kind: kind, id: String(parts[2]))
        }
        guard let url = URL(string: string), url.host?.hasSuffix("spotify.com") == true else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" && !$0.hasPrefix("intl-") && $0 != "embed" }
        guard parts.count >= 2, let kind = Kind(rawValue: parts[0]) else { return nil }
        return Link(kind: kind, id: parts[1])
    }

    static func isSpotify(_ string: String) -> Bool {
        string.hasPrefix("spotify:") || URL(string: string)?.host?.hasSuffix("spotify.com") == true
    }

    static func fetch(_ link: Link) async throws -> Collection {
        async let entityTask = embedEntity(link)
        async let coverTask = coverURL(link)
        let entity = try await entityTask
        let cover = await coverTask

        let name = (entity["name"] as? String) ?? (entity["title"] as? String) ?? "Spotify"

        switch link.kind {
        case .track:
            let artists = (entity["artists"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
            let track = SpotifyTrack(
                id: link.id, title: name, artists: artists,
                duration: (entity["duration"] as? Double).map { $0 / 1000 },
                album: nil, cover: cover)
            return Collection(name: name, kind: .track, tracks: [track])

        case .album, .playlist:
            let list = entity["trackList"] as? [[String: Any]] ?? []
            let tracks = list.compactMap { t -> SpotifyTrack? in
                guard let title = t["title"] as? String,
                      let uri = t["uri"] as? String else { return nil }
                let artists = (t["subtitle"] as? String ?? "")
                    .replacingOccurrences(of: "\u{00A0}", with: " ")
                    .components(separatedBy: ", ")
                    .filter { !$0.isEmpty }
                return SpotifyTrack(
                    id: String(uri.split(separator: ":").last ?? ""),
                    title: title, artists: artists,
                    duration: (t["duration"] as? Double).map { $0 / 1000 },
                    album: link.kind == .album ? name : nil,
                    // Playlist tracks come from different albums, so only albums share a cover.
                    cover: link.kind == .album ? cover : nil)
            }
            guard !tracks.isEmpty else { throw Failure.unreadable }
            return Collection(name: name, kind: link.kind, tracks: tracks)
        }
    }

    private static func embedEntity(_ link: Link) async throws -> [String: Any] {
        var request = URLRequest(url: URL(string: "https://open.spotify.com/embed/\(link.kind.rawValue)/\(link.id)")!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        guard let start = html.range(of: #"<script id="__NEXT_DATA__" type="application/json">"#),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)),
              let entity = (root as AnyObject).value(forKeyPath: "props.pageProps.state.data.entity") as? [String: Any]
        else { throw Failure.unreadable }
        return entity
    }

    private static func coverURL(_ link: Link) async -> URL? {
        var components = URLComponents(string: "https://open.spotify.com/oembed")!
        components.queryItems = [URLQueryItem(name: "url", value: "https://open.spotify.com/\(link.kind.rawValue)/\(link.id)")]
        guard let (data, _) = try? await URLSession.shared.data(from: components.url!),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let thumb = json["thumbnail_url"] as? String else { return nil }
        return URL(string: thumb)
    }

    // MARK: - Matching

    /// Loose comparison key: lowercase letters and digits only, with "(feat. …)" style suffixes removed.
    static func normalize(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: #"\s*[\(\[].*?[\)\]]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" - .*$"#, with: "", options: .regularExpression)
            .filter { $0.isLetter || $0.isNumber }
    }

    static func titlesMatch(_ candidate: String, _ track: SpotifyTrack) -> Bool {
        let a = normalize(candidate), b = normalize(track.title)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a.contains(b) || b.contains(a)
    }

    static func musicSearchURL(for track: SpotifyTrack) -> String {
        var c = URLComponents(string: "https://music.youtube.com/search")!
        c.queryItems = [URLQueryItem(name: "q", value: (track.artists + [track.title]).joined(separator: " "))]
        return c.url!.absoluteString + "#songs"
    }

    static func videoSearchQuery(for track: SpotifyTrack) -> String {
        "ytsearch8:\(track.artists.joined(separator: " ")) - \(track.title) audio"
    }

    /// Escapes a literal for use as the FROM side of yt-dlp's --parse-metadata. The empty
    /// `%(pluck|)s` prefix stops a one-word value like "GUERILLAZ" being read as a field name.
    static func metadataLiteral(_ s: String) -> String {
        "%(pluck|)s" + s.replacingOccurrences(of: "\\", with: "")
            .replacingOccurrences(of: "%", with: "%%")
            .replacingOccurrences(of: ":", with: "\\:")
    }
}
