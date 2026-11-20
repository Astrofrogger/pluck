import Foundation

/// Streaming services whose links Pluck accepts. Their audio is DRM-protected, so Pluck reads
/// the song's details and matches it on YouTube Music.
enum MusicService: String, Sendable, Codable {
    case spotify, apple

    var name: String {
        switch self {
        case .spotify: "Spotify"
        case .apple: "Apple Music"
        }
    }
}

/// A track read from Spotify or Apple Music. The audio is matched on YouTube Music and tagged
/// with the service's metadata. (Named for Spotify, which came first; history files use it.)
struct SpotifyTrack: Sendable, Codable {
    var id: String
    var title: String
    var artists: [String]
    var duration: Double?
    var album: String?
    var cover: URL?
    /// nil for tracks saved before Apple Music was supported, which are all Spotify.
    var service: MusicService?
    /// The track's own page, when it isn't a Spotify one.
    var link: String?
    var trackNumber: Int?
    var trackCount: Int?
    var discNumber: Int?
    var year: String?
    /// Large album art to embed instead of YouTube Music's thumbnail.
    var artwork: URL?

    var source: MusicService { service ?? .spotify }
    var url: String { link ?? "https://open.spotify.com/track/\(id)" }
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
        /// How many songs the album or playlist really has, when Spotify's page says (the embed lists only the first 50–100).
        var total: Int? = nil

        /// The embed left songs out (a few missing from a short list are unavailable ones, not a cut-off).
        var isCutOff: Bool { (total ?? 0) > tracks.count && tracks.count >= 50 }
    }

    enum Failure: LocalizedError {
        case unsupported, unreadable

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "Only Spotify songs, albums and playlists can be downloaded.")
            case .unreadable: String(localized: "Couldn’t read this Spotify page. It may be private or region-locked.")
            }
        }
    }

    /// Matches open.spotify.com/track/ID, /intl-xx/album/ID, /embed/…, /user/NAME/playlist/ID, play.spotify.com,
    /// spotify:playlist:ID and spotify:user:NAME:playlist:ID. Short share links (spotify.link) need `resolveShortLink` first.
    static func parse(_ string: String) -> Link? {
        let parts: [String]
        if string.hasPrefix("spotify:") {
            parts = string.split(separator: ":").dropFirst().map(String.init)
        } else if let url = URL(string: string), let host = url.host?.lowercased(), host == "spotify.com" || host.hasSuffix(".spotify.com") {
            parts = url.pathComponents.filter { $0 != "/" }
        } else {
            return nil
        }
        // The first song/album/playlist word, wherever it sits (after intl-xx, embed or user/NAME).
        guard let at = parts.firstIndex(where: { Kind(rawValue: $0) != nil }), at + 1 < parts.count,
              let kind = Kind(rawValue: parts[at]), !parts[at + 1].isEmpty else { return nil }
        return Link(kind: kind, id: parts[at + 1])
    }

    /// Hosts of Spotify's short share links (the phone's share sheet gives spotify.link ones).
    static let shortHosts: Set<String> = ["spotify.link", "spotify.app.link", "spoti.fi"]

    static func isShortLink(_ string: String) -> Bool {
        URL(string: string)?.host.map { shortHosts.contains($0.lowercased()) } == true
    }

    static func isSpotify(_ string: String) -> Bool {
        guard !string.hasPrefix("spotify:") else { return true }
        guard let host = URL(string: string)?.host?.lowercased() else { return false }
        return host == "spotify.com" || host.hasSuffix(".spotify.com") || shortHosts.contains(host)
    }

    /// A short share link to the open.spotify.com link it stands for: the redirect's end, or (spotify.link ends on a
    /// Branch page that sends you on with JavaScript) the open.spotify.com link written in that page.
    static func resolveShortLink(_ string: String) async throws -> String {
        guard let url = URL(string: string) else { throw Failure.unreadable }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("Pluck", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        if let end = response.url?.absoluteString, isSpotify(end), !isShortLink(end), !end.hasPrefix("spotify:") { return end }
        guard let found = linkInPage(String(decoding: data, as: UTF8.self)) else { throw Failure.unreadable }
        return found
    }

    /// The open.spotify.com link in a redirect page: a song/album/playlist one first, else any (an episode's, so
    /// it gets the clear "only songs…" message).
    static func linkInPage(_ html: String) -> String? {
        let found = html.matches(of: #/https://open\.spotify\.com/[^"'<>\s\\]+/#)
            .map { String($0.output).replacingOccurrences(of: "&amp;", with: "&") }
        return found.first { parse($0) != nil } ?? found.first
    }

    static func fetch(_ link: Link) async throws -> Collection {
        async let entityTask = embedEntity(link)
        async let coverTask = coverURL(link)
        async let totalTask = link.kind == .track ? nil : pageTotal(link)
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
            return Collection(name: name, kind: link.kind, tracks: tracks, total: await totalTask)
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

    /// The song count from the normal open.spotify.com page (server-rendered for a plain user agent): its
    /// base64 "initialState" has content.totalCount (playlists) or tracksV2.totalCount (albums).
    private static func pageTotal(_ link: Link) async -> Int? {
        var request = URLRequest(url: URL(string: "https://open.spotify.com/\(link.kind.rawValue)/\(link.id)")!, timeoutInterval: 15)
        request.setValue("Pluck", forHTTPHeaderField: "User-Agent")
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return pageTotal(in: String(decoding: data, as: UTF8.self), link: link)
    }

    static func pageTotal(in html: String, link: Link) -> Int? {
        guard let start = html.range(of: #"<script id="initialState" type="text/plain">"#),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let decoded = Data(base64Encoded: html[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)),
              let root = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any],
              let items = (root["entities"] as? [String: Any])?["items"] as? [String: Any],
              let entity = items["spotify:\(link.kind.rawValue):\(link.id)"] as? [String: Any] else { return nil }
        return ((entity["content"] ?? entity["tracksV2"]) as? [String: Any])?["totalCount"] as? Int
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


/// Spotify and Apple Music links behind one interface, so downloads, playlists and matching
/// treat both the same way.
enum MusicLinks {
    struct Link {
        let service: MusicService
        let kind: Spotify.Kind
        let id: String
        fileprivate let spotify: Spotify.Link?
        fileprivate let apple: AppleMusic.Link?
    }

    static func parse(_ string: String) -> Link? {
        if let link = Spotify.parse(string) {
            return Link(service: .spotify, kind: link.kind, id: link.id, spotify: link, apple: nil)
        }
        if let link = AppleMusic.parse(string) {
            return Link(service: .apple, kind: link.kind, id: link.id, spotify: nil, apple: link)
        }
        return nil
    }

    /// A Spotify or Apple Music address, even one Pluck can't read (artist pages…).
    static func isMusicLink(_ string: String) -> Bool {
        Spotify.isSpotify(string) || AppleMusic.isAppleMusic(string)
    }

    static func service(of string: String) -> MusicService? {
        Spotify.isSpotify(string) ? .spotify : AppleMusic.isAppleMusic(string) ? .apple : nil
    }

    static func fetch(_ link: Link) async throws -> Spotify.Collection {
        if let apple = link.apple { return try await AppleMusic.fetch(apple) }
        return try await Spotify.fetch(link.spotify!)
    }

    static func unsupported(_ service: MusicService) -> String {
        switch service {
        case .spotify: Spotify.Failure.unsupported.localizedDescription
        case .apple: AppleMusic.Failure.unsupported.localizedDescription
        }
    }
}
