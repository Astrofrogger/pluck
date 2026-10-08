import Foundation

// MARK: - File names

/// How downloaded files are named. Built as yt-dlp output templates (without the extension).
enum FileNaming: String, CaseIterable, Identifiable {
    case automatic, title, artistTitle, titleYear, channelTitle, custom

    var id: String { rawValue }

    var label: String {
        switch self {
        case .automatic: String(localized: "Automatic")
        case .title: String(localized: "Title")
        case .artistTitle: String(localized: "Artist - Title")
        case .titleYear: String(localized: "Title (Year)")
        case .channelTitle: String(localized: "Channel - Title")
        case .custom: String(localized: "Custom")
        }
    }

    static var current: FileNaming {
        FileNaming(rawValue: UserDefaults.standard.string(forKey: Prefs.fileNaming) ?? "") ?? .automatic
    }

    /// "Artist - " only when the site knows the artist (YouTube Music, Spotify matches…).
    private static let artistPrefix = "%(artist&{} - |)s"

    /// The yt-dlp template for an item, without extension.
    static func template(isAudio: Bool) -> String {
        switch current {
        case .automatic: isAudio ? artistPrefix + "%(track,title)s" : "%(title)s"
        case .title: "%(title)s"
        case .artistTitle: "%(artist,creator,uploader,channel)s - %(track,title)s"
        case .titleYear: "%(title)s (%(release_year,upload_date>%Y)s)"
        case .channelTitle: "%(channel,uploader)s - %(title)s"
        case .custom: customTemplate(UserDefaults.standard.string(forKey: Prefs.customFileName) ?? "") ?? "%(title)s"
        }
    }

    /// Placeholders for custom names, with the yt-dlp field each stands for and a sample value.
    static let tokens: [(token: String, field: String, sample: String)] = [
        ("{title}", "%(track,title)s", "Spring"),
        ("{artist}", "%(artist,creator,uploader,channel)s", "Blender Studio"),
        ("{album}", "%(album|)s", "Open Movies"),
        ("{channel}", "%(channel,uploader)s", "Blender Studio"),
        ("{year}", "%(release_year,upload_date>%Y)s", "2019"),
        ("{date}", "%(upload_date>%Y-%m-%d)s", "2019-04-04"),
        ("{id}", "%(id)s", "WhWc3b3KhnY"),
    ]

    /// Turns "{artist} - {title}" into a yt-dlp template. Literal text can't contain template
    /// syntax or folder separators. Returns nil when there's nothing usable.
    static func customTemplate(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard tokens.contains(where: { trimmed.contains($0.token) }) else { return nil }
        var result = ""
        var rest = Substring(trimmed)
        while !rest.isEmpty {
            if let token = tokens.first(where: { rest.hasPrefix($0.token) }) {
                result += token.field
                rest = rest.dropFirst(token.token.count)
            } else {
                result += literal(rest.first!)
                rest = rest.dropFirst()
            }
        }
        return result
    }

    private static func literal(_ c: Character) -> String {
        switch c {
        case "%": "%%"
        case "/", ":", "\\": "-"
        default: String(c)
        }
    }

    /// What a custom name looks like with sample values.
    static func preview(_ text: String) -> String? {
        guard customTemplate(text) != nil else { return nil }
        var result = text.trimmingCharacters(in: .whitespaces)
        for token in tokens { result = result.replacingOccurrences(of: token.token, with: token.sample) }
        return result.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + ".mp4"
    }
}

// MARK: - Folders

enum Folders {
    /// A safe folder name: no separators or leading dots, not too long.
    static func sanitize(_ name: String) -> String {
        var cleaned = name
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }
        if cleaned.count > 100 { cleaned = String(cleaned.prefix(100)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? String(localized: "Playlist") : cleaned
    }
}

// MARK: - Same link?

extension Links {
    private static let trackingParameters: Set<String> = ["si", "feature", "fbclid", "gclid", "igshid", "ref", "pp", "t"]

    /// A key that's equal for two links to the same video or track, ignoring link style and
    /// tracking codes (youtu.be vs youtube.com/watch, ?si=…).
    static func identity(_ link: String) -> String {
        if let spotify = Spotify.parse(link) { return "spotify:\(spotify.kind.rawValue):\(spotify.id)" }
        guard let url = URL(string: link), var host = url.host?.lowercased() else { return link }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        if host == "youtu.be", let id = url.pathComponents.dropFirst().first { return "youtube:\(id)" }
        if host.hasSuffix("youtube.com") {
            if let id = items.first(where: { $0.name == "v" })?.value { return "youtube:\(id)" }
            let parts = url.pathComponents
            if parts.count >= 3, ["shorts", "live", "embed"].contains(parts[1]) { return "youtube:\(parts[2])" }
        }
        let kept = items
            .filter { !trackingParameters.contains($0.name) && !$0.name.hasPrefix("utm_") }
            .sorted { $0.name < $1.name }
            .map { "\($0.name)=\($0.value ?? "")" }
        var path = url.path
        while path.hasSuffix("/") { path.removeLast() }
        return host + path + (kept.isEmpty ? "" : "?" + kept.joined(separator: "&"))
    }
}
