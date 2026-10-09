import Foundation

/// Keeps the download list across launches: finished, failed and cancelled downloads (the most
/// recent 200) are saved to Application Support/Pluck/history.json.
enum History {
    private struct Entry: Codable {
        var url: String
        var title: String
        var uploader: String?
        var duration: Double?
        var thumbnail: URL?
        var options: DownloadOptions
        var folder: String
        var spotify: SpotifyTrack?
        var state: String
        var filePath: String?
        var fileSize: Int64?
        var errorMessage: String?
        var finishedAt: Date?
        var clip: ClipRange?
        var sourceAudio: String?
        var hasLyrics: Bool?
        var progress: Double?
        var resolvedURL: String?
        var splitChapters: Bool?
        var chapterCount: Int?
        var conversion: Conversion?
        var addedToMusic: Bool?
        var transcriptID: String?
        var spokenLanguage: String?
    }

    static let limit = 200

    private static var fileURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/history.json")
    }

    @MainActor static func load() -> [DownloadItem] {
        guard let data = try? Data(contentsOf: fileURL),
              let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return [] }
        return entries.map { e in
            let item = DownloadItem(url: e.url, options: e.options, folder: e.folder)
            item.spotify = e.spotify
            item.title = e.title
            item.uploader = e.uploader
            item.duration = e.duration
            item.thumbnail = e.thumbnail
            item.fileURL = e.filePath.map { URL(fileURLWithPath: $0) }
            item.fileSize = e.fileSize
            item.errorMessage = e.errorMessage
            item.finishedAt = e.finishedAt
            item.clip = e.clip
            item.sourceAudio = e.sourceAudio
            item.hasLyrics = e.hasLyrics ?? false
            item.resolvedURL = e.resolvedURL
            item.splitChapters = e.splitChapters ?? false
            item.chapterCount = e.chapterCount
            item.conversion = e.conversion
            item.addedToMusic = e.addedToMusic ?? false
            item.transcriptID = e.transcriptID
            item.spokenLanguage = e.spokenLanguage
            item.progress = e.state == "finished" ? 1 : (e.progress ?? 0)
            item.state = switch e.state {
            case "finished": .finished
            case "cancelled": .cancelled
            case "paused": .paused
            default: .failed
            }
            return item
        }
    }

    /// Saves the list. Downloads still running (only when quitting) are saved as interrupted,
    /// so they come back with Try Again.
    @MainActor static func save(_ items: [DownloadItem]) {
        let entries = items.prefix(limit).map { item -> Entry in
            let state: String
            var error = item.errorMessage
            switch item.state {
            case .finished: state = "finished"
            case .cancelled: state = "cancelled"
            case .failed: state = "failed"
            // Unfinished downloads (only when quitting) come back paused, ready to resume.
            case .queued, .starting, .downloading, .processing, .paused:
                state = "paused"
                error = nil
            }
            return Entry(url: item.url, title: item.title, uploader: item.uploader, duration: item.duration,
                         thumbnail: item.thumbnail, options: item.options, folder: item.folder,
                         spotify: item.spotify, state: state, filePath: item.fileURL?.path,
                         fileSize: item.fileSize, errorMessage: error, finishedAt: item.finishedAt,
                         clip: item.clip, sourceAudio: item.sourceAudio, hasLyrics: item.hasLyrics,
                         progress: item.progress, resolvedURL: item.spotify != nil ? item.resolvedURL : nil,
                         splitChapters: item.splitChapters, chapterCount: item.chapterCount,
                         conversion: item.conversion, addedToMusic: item.addedToMusic,
                         transcriptID: item.transcriptID, spokenLanguage: item.spokenLanguage)
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONEncoder().encode(Array(entries)).write(to: fileURL, options: .atomic)
        } catch {
            // Losing the history isn't worth interrupting anyone over.
        }
    }
}
