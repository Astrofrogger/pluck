import Foundation

/// Spotify links (-PluckScreenshotOnly spotify): short share links read from a saved Branch page (and one real
/// spotify.link, live), intl/si/user/play variants, kinds that can't be downloaded, and the "only the first N" note.
extension PhotoSelfTest {
    static func spotifyTest() async {
        func kind(_ s: String) -> String { Spotify.parse(s).map { "\($0.kind.rawValue):\($0.id)" } ?? "nil" }
        let id = "7JmS9HKd8g6jNDqFnb1eMe"
        for link in ["https://open.spotify.com/playlist/\(id)", "https://open.spotify.com/intl-nl/playlist/\(id)?si=vcyKW6ykRn66oiRYeeXBzA",
                     "https://open.spotify.com/playlist/\(id)/", "https://play.spotify.com/playlist/\(id)",
                     "https://open.spotify.com/embed/playlist/\(id)?utm_source=generator", "https://open.spotify.com/user/someone/playlist/\(id)",
                     "spotify:playlist:\(id)", "spotify:user:someone:playlist:\(id)", "HTTPS://OPEN.SPOTIFY.COM/playlist/\(id)"] {
            check("spotify: parses \(link)", kind(link) == "playlist:\(id)", kind(link))
        }
        for link in ["https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk", "https://open.spotify.com/show/2MAi0BvDc6GTFvKFPXnkCL",
                     "https://open.spotify.com/artist/0OdUWJ0sBjDrqHygGUXeCF", "https://open.spotify.com/user/someone",
                     "spotify:episode:4rOoJ6Egrf8K2IrywzwOMk", "https://notspotify.com/track/abc"] {
            check("spotify: not downloadable \(link)", Spotify.parse(link) == nil, kind(link))
        }
        check("spotify: episode is a music link with the clear message",
              MusicLinks.isMusicLink("https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk")
              && MusicLinks.unsupported(.spotify).contains("Spotify") && !MusicLinks.isMusicLink("https://notspotify.com/track/abc"))
        for link in ["https://spotify.link/zLIDHxA0bKb", "https://spotify.app.link/zLIDHxA0bKb?_p=c71c29c0991c66f2e2038cfdea", "https://spoti.fi/3abcDEF"] {
            check("spotify: short link \(link)", Spotify.isShortLink(link) && MusicLinks.isMusicLink(link) && Links.validated(link) != nil)
        }

        // What spotify.app.link returns (saved 2026-11-20): a page that sends you on with JavaScript.
        let branch = """
        <html><head><title>Spotify</title></head><body><div class="content">You can also <a class="secondary-action" \
        href="https://open.spotify.com/playlist/\(id)?si=vcyKW6ykRn66oiRYeeXBzA&amp;pi=a--40RIH-iQfOc&amp;utm_source=copy-link">open in the web player</a></div>
        <script>if (!hasURI) { window.top.location = validateProtocol("https://open.spotify.com/playlist/\(id)?si=vcyKW6ykRn66oiRYeeXBzA&pi=a--40RIH-iQfOc"); }</script>
        </body></html>
        """
        let found = Spotify.linkInPage(branch) ?? "nil"
        check("spotify: link in a Branch page", kind(found) == "playlist:\(id)" && !found.contains("&amp;"), found)
        let episodePage = #"<script>window.top.location = validateProtocol("https://open.spotify.com/episode/4rOoJ6Egrf8K2IrywzwOMk");</script>"#
        check("spotify: an episode's short link still ends on its page (the clear message)",
              Spotify.linkInPage(episodePage).map { Spotify.isSpotify($0) && Spotify.parse($0) == nil } == true)
        check("spotify: no link in a page", Spotify.linkInPage("<html>nothing</html>") == nil)

        // The song count from open.spotify.com's initialState, and when the note shows.
        let link = Spotify.Link(kind: .playlist, id: id)
        let state = try! JSONSerialization.data(withJSONObject: ["entities": ["items": ["spotify:playlist:\(id)": ["content": ["totalCount": 150]]]]])
        let page = #"<script id="initialState" type="text/plain">"# + state.base64EncodedString() + "</script>"
        check("spotify: page total", Spotify.pageTotal(in: page, link: link) == 150, "\(String(describing: Spotify.pageTotal(in: page, link: link)))")
        let albumState = try! JSONSerialization.data(withJSONObject: ["entities": ["items": ["spotify:album:x": ["tracksV2": ["totalCount": 14]]]]])
        check("spotify: album total", Spotify.pageTotal(in: #"<script id="initialState" type="text/plain">"# + albumState.base64EncodedString() + "</script>",
                                                      link: Spotify.Link(kind: .album, id: "x")) == 14)
        let song = SpotifyTrack(id: "a", title: "A", artists: ["B"])
        check("spotify: cut-off at 100 of 150", Spotify.Collection(name: "", kind: .playlist, tracks: Array(repeating: song, count: 100), total: 150).isCutOff)
        check("spotify: no note for a full list", !Spotify.Collection(name: "", kind: .playlist, tracks: Array(repeating: song, count: 50), total: 50).isCutOff)
        check("spotify: no note for 2 unavailable of 30", !Spotify.Collection(name: "", kind: .playlist, tracks: Array(repeating: song, count: 28), total: 30).isCutOff)
        check("spotify: no note without a total", !Spotify.Collection(name: "", kind: .playlist, tracks: Array(repeating: song, count: 100)).isCutOff)
        check("spotify: yt-dlp release date", Updater.releaseDate("2026.10.26.232857").map {
            Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: $0) == DateComponents(year: 2026, month: 10, day: 26) } == true
              && Updater.releaseDate("abc") == nil)

        // Live (network): the real short link from a Spotify Community post, and a playlist of 150.
        do {
            let full = try await Spotify.resolveShortLink("https://spotify.link/zLIDHxA0bKb")
            check("spotify live: spotify.link resolves", kind(full) == "playlist:\(id)", full)
        } catch { check("spotify live: spotify.link resolves", false, error.localizedDescription) }
        do {
            let all = try await Spotify.fetch(Spotify.Link(kind: .playlist, id: "37i9dQZF1DX4UtSsGT1Sbe"))
            note("spotify live: All Out 80s lists \(all.tracks.count) of \(all.total ?? -1)")
            check("spotify live: big playlist is marked cut off", all.isCutOff && (all.total ?? 0) > all.tracks.count)
            let small = try await Spotify.fetch(Spotify.Link(kind: .album, id: "2noRn2Aes5aoNVsU6iWThc"))
            check("spotify live: album not cut off", !small.isCutOff && small.total == small.tracks.count, "\(small.tracks.count) of \(small.total ?? -1)")
        } catch { check("spotify live: fetch", false, error.localizedDescription) }
        // The whole way in: a pasted short link ends up in the playlist picker, read, with its note when cut off.
        if let manager = AppDelegate.shared?.manager {
            manager.add(["https://spotify.link/zLIDHxA0bKb"], folder: NSTemporaryDirectory(), fromOtherDevice: false)
            var pick: PlaylistPick?
            for _ in 0..<120 {
                pick = manager.picks.first { Spotify.parse($0.sourceURL)?.id == id }
                if let pick, pick.phase != .loading { break }
                try? await Task.sleep(for: .milliseconds(250))
            }
            check("spotify live: short link opens the picker", pick?.phase == .ready && pick?.entries.isEmpty == false
                  && !manager.items.contains { $0.url.contains("spotify.link") },
                  "\(String(describing: pick?.phase)) \(pick?.entries.count ?? -1) note \(pick?.note ?? "-")")
            if let pick { manager.cancelPick(pick) }
        }
    }
}
