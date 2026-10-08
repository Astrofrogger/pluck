import Foundation

/// Song lyrics from LRCLIB (https://lrclib.net), a free, open lyrics database, written into the
/// downloaded file so they show up in Apple Music and on iPhone.
enum Lyrics {
    /// Formats whose lyrics tag ffmpeg can write without disturbing the cover art.
    static let supportedExtensions: Set<String> = ["mp3", "m4a", "flac"]

    /// Looks up plain lyrics by artist, title and length. Nil when unknown or instrumental.
    static func find(artist: String, title: String, duration: Double?) async -> String? {
        if let exact = await get(artist: artist, title: title, duration: duration) { return exact }
        return await search(artist: artist, title: title, duration: duration)
    }

    private static func get(artist: String, title: String, duration: Double?) async -> String? {
        var c = URLComponents(string: "https://lrclib.net/api/get")!
        c.queryItems = [URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "track_name", value: title)]
        if let duration { c.queryItems?.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        guard let json = await fetch(c.url!) as? [String: Any] else { return nil }
        return text(from: json)
    }

    /// Fallback when the exact lookup misses: the closest match in length (within 5 seconds).
    private static func search(artist: String, title: String, duration: Double?) async -> String? {
        var c = URLComponents(string: "https://lrclib.net/api/search")!
        c.queryItems = [URLQueryItem(name: "artist_name", value: artist), URLQueryItem(name: "track_name", value: title)]
        guard let results = await fetch(c.url!) as? [[String: Any]] else { return nil }
        let candidates = results.filter { result in
            guard let duration, let length = result["duration"] as? Double else { return true }
            return abs(length - duration) <= 5
        }
        let best = candidates.min { a, b in
            let da = abs((a["duration"] as? Double ?? 0) - (duration ?? 0))
            let db = abs((b["duration"] as? Double ?? 0) - (duration ?? 0))
            return da < db
        }
        return best.flatMap(text(from:))
    }

    private static func fetch(_ url: URL) async -> Any? {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("Pluck (https://github.com/Astrofrogger/pluck)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func text(from json: [String: Any]) -> String? {
        if json["instrumental"] as? Bool == true { return nil }
        if let plain = json["plainLyrics"] as? String, !plain.isEmpty { return clamp(plain) }
        // Only time-synced lyrics: drop the [mm:ss.xx] stamps.
        guard let synced = json["syncedLyrics"] as? String, !synced.isEmpty else { return nil }
        let lines = synced.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: #"^\[[0-9:.]+\]\s?"#, with: "", options: .regularExpression)
        }
        return clamp(lines.joined(separator: "\n"))
    }

    private static func clamp(_ text: String) -> String {
        String(text.prefix(20_000)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "H.LLS, Lucy Park" → "H.LLS": LRCLIB matches the main artist best.
    static func mainArtist(_ artist: String) -> String {
        artist.components(separatedBy: CharacterSet(charactersIn: ",&")).first?
            .trimmingCharacters(in: .whitespaces) ?? artist
    }
}
