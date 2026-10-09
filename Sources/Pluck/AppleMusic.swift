import Foundation

/// Apple Music links. Songs and albums come from Apple's public catalog (the iTunes Search
/// API); playlists from the data in their public web page. Like Spotify, the audio itself is
/// matched on YouTube Music.
enum AppleMusic {
    struct Link {
        let kind: Spotify.Kind
        let id: String
        /// Country code from the link, e.g. "us" or "be"; the catalog differs per country.
        let storefront: String
        let url: String
    }

    enum Failure: LocalizedError {
        case unsupported, unreadable

        var errorDescription: String? {
            switch self {
            case .unsupported: String(localized: "Only Apple Music song, album and playlist links are supported.")
            case .unreadable: String(localized: "Couldn’t read this Apple Music page. It may be private or not available in your country.")
            }
        }
    }

    static func isAppleMusic(_ string: String) -> Bool {
        URL(string: string)?.host?.lowercased() == "music.apple.com"
    }

    /// music.apple.com/us/album/name/123?i=456 (a song on an album), /us/song/name/456,
    /// /us/album/name/123 and /us/playlist/name/pl.abc.
    static func parse(_ string: String) -> Link? {
        guard let url = URL(string: string), isAppleMusic(string) else { return nil }
        let parts = url.pathComponents.filter { $0 != "/" }
        guard parts.count >= 3, let id = parts.last else { return nil }
        let storefront = parts[0].count == 2 ? parts[0] : "us"
        let kind = parts[0].count == 2 ? parts[1] : parts[0]
        let songOnAlbum = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first { $0.name == "i" }?.value
        switch kind {
        case "album" where songOnAlbum != nil:
            return Link(kind: .track, id: songOnAlbum!, storefront: storefront, url: string)
        case "song":
            return Link(kind: .track, id: id, storefront: storefront, url: string)
        case "album":
            return Link(kind: .album, id: id, storefront: storefront, url: string)
        case "playlist":
            return Link(kind: .playlist, id: id, storefront: storefront, url: string)
        default:
            return nil
        }
    }

    static func fetch(_ link: Link) async throws -> Spotify.Collection {
        switch link.kind {
        case .track, .album:
            var components = URLComponents(string: "https://itunes.apple.com/lookup")!
            components.queryItems = [
                URLQueryItem(name: "id", value: link.id),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "country", value: link.storefront),
                URLQueryItem(name: "limit", value: "300"),
            ]
            let (data, _) = try await URLSession.shared.data(from: components.url!)
            let results = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["results"] as? [[String: Any]] ?? []
            let tracks = results.filter { $0["wrapperType"] as? String == "track" && $0["kind"] as? String == "song" }
                .map(track(from:))
            guard !tracks.isEmpty else { throw Failure.unreadable }
            let album = results.first { $0["wrapperType"] as? String == "collection" }?["collectionName"] as? String
            let name = link.kind == .album ? album ?? tracks[0].album ?? "Apple Music" : tracks[0].title
            return Spotify.Collection(name: name, kind: link.kind, tracks: link.kind == .track ? [tracks[0]] : tracks)
        case .playlist:
            return try await playlist(link)
        }
    }

    /// A song from the catalog API.
    private static func track(from r: [String: Any]) -> SpotifyTrack {
        let id = (r["trackId"] as? Int).map(String.init) ?? UUID().uuidString
        let art = r["artworkUrl100"] as? String
        var page = r["trackViewUrl"] as? String
        if let p = page, var c = URLComponents(string: p) {
            c.queryItems = c.queryItems?.filter { $0.name == "i" }   // drop the "uo" tracking code
            page = c.url?.absoluteString
        }
        return SpotifyTrack(
            id: id,
            title: r["trackName"] as? String ?? "",
            artists: [r["artistName"] as? String].compactMap { $0 },
            duration: (r["trackTimeMillis"] as? Double).map { $0 / 1000 },
            album: r["collectionName"] as? String,
            cover: art.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: "600x600bb")) },
            service: .apple,
            link: page,
            trackNumber: r["trackNumber"] as? Int,
            trackCount: r["trackCount"] as? Int,
            discNumber: r["discNumber"] as? Int,
            year: (r["releaseDate"] as? String).map { String($0.prefix(4)) },
            artwork: art.flatMap { URL(string: $0.replacingOccurrences(of: "100x100bb", with: artworkSize)) })
    }

    /// Embedded art: sharp on any screen without making each song megabytes bigger.
    private static let artworkSize = "1500x1500bb"

    /// A public playlist, read from the data Apple's web page is built from.
    private static func playlist(_ link: Link) async throws -> Spotify.Collection {
        var request = URLRequest(url: URL(string: link.url)!)
        request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
                         forHTTPHeaderField: "User-Agent")
        let (data, _) = try await URLSession.shared.data(for: request)
        let html = String(decoding: data, as: UTF8.self)
        guard let start = html.range(of: #"<script type="application/json" id="serialized-server-data">"#),
              let end = html.range(of: "</script>", range: start.upperBound..<html.endIndex),
              let root = try? JSONSerialization.jsonObject(with: Data(html[start.upperBound..<end.lowerBound].utf8)) as? [String: Any],
              let page = ((root["data"] as? [[String: Any]])?.first?["data"] as? [String: Any]),
              let sections = page["sections"] as? [[String: Any]]
        else { throw Failure.unreadable }

        let items = sections.compactMap { $0["items"] as? [[String: Any]] }
        let name = items.first?.first?["title"] as? String ?? "Apple Music"
        let tracks = items.dropFirst().flatMap { $0 }.compactMap { item -> SpotifyTrack? in
            guard let title = item["title"] as? String, let artist = item["artistName"] as? String,
                  item["duration"] != nil else { return nil }
            // "track-lockup - pl.… - 6792884088"
            let id = (item["id"] as? String)?.components(separatedBy: " - ").last ?? UUID().uuidString
            let template = (item["artwork"] as? [String: Any]).flatMap { $0["dictionary"] as? [String: Any] }?["url"] as? String
            // ".../{w}x{h}bb.{f}" (sometimes "{w}x{h}{c}.{f}") → ".../600x600bb.jpg"
            let art = { (size: String) in
                template.flatMap { URL(string: $0.replacingOccurrences(of: #"\{w\}x\{h\}[^/]*$"#, with: size + ".jpg", options: .regularExpression)) }
            }
            let album = ((item["tertiaryLinks"] as? [[String: Any]])?.first?["title"]) as? String
            return SpotifyTrack(
                id: id, title: title, artists: [artist],
                duration: (item["duration"] as? Double).map { $0 / 1000 },
                album: album, cover: art("600x600bb"), service: .apple,
                link: "https://music.apple.com/\(link.storefront)/song/\(id)",
                artwork: art(artworkSize))
        }
        guard !tracks.isEmpty else { throw Failure.unreadable }
        return Spotify.Collection(name: name, kind: .playlist, tracks: tracks)
    }
}
