import Foundation
import Observation

// MARK: - Format options

enum MediaKind: String {
    case video, audio
}

enum Resolution: Int, CaseIterable, Identifiable {
    case best = 0, p2160 = 2160, p1440 = 1440, p1080 = 1080, p720 = 720, p480 = 480, p360 = 360

    var id: Int { rawValue }

    var label: String {
        switch self {
        case .best: "Best Available"
        case .p2160: "2160p (4K)"
        case .p1440: "1440p (2K)"
        default: "\(rawValue)p"
        }
    }

    var shortLabel: String {
        switch self {
        case .best: "Best"
        case .p2160: "4K"
        default: "\(rawValue)p"
        }
    }
}

enum VideoCodec: String, CaseIterable, Identifiable {
    case compatible, modern

    var id: String { rawValue }

    var label: String {
        switch self {
        case .compatible: "H.264 (plays everywhere)"
        case .modern: "AV1 / VP9 (sharper, smaller)"
        }
    }
}

enum VideoContainer: String, CaseIterable, Identifiable {
    case mp4, mkv, webm

    var id: String { rawValue }
    var label: String { rawValue.uppercased() }
}

enum AudioFormat: String, CaseIterable, Identifiable {
    case original, m4a, mp3, opus, flac, wav

    var id: String { rawValue }

    var label: String {
        switch self {
        case .original: "Original (no conversion)"
        case .m4a: "M4A (AAC)"
        case .mp3: "MP3"
        case .opus: "Opus"
        case .flac: "FLAC (lossless)"
        case .wav: "WAV (uncompressed)"
        }
    }

    var shortLabel: String {
        self == .original ? "Audio" : rawValue.uppercased()
    }

    /// Lossy formats where a target bitrate makes sense.
    var supportsBitrate: Bool { self == .m4a || self == .mp3 || self == .opus }
}

enum AudioBitrate: Int, CaseIterable, Identifiable {
    case best = 0, k320 = 320, k256 = 256, k192 = 192, k128 = 128

    var id: Int { rawValue }
    var label: String { self == .best ? "Best (VBR)" : "\(rawValue) kbps" }
}

/// A snapshot of the format settings, captured when a download is added.
struct DownloadOptions: Equatable {
    var kind: MediaKind = .video
    var resolution: Resolution = .best
    var codec: VideoCodec = .compatible
    var container: VideoContainer = .mp4
    var prefer60fps = false
    var audioFormat: AudioFormat = .m4a
    var audioBitrate: AudioBitrate = .best

    static var current: DownloadOptions {
        let d = UserDefaults.standard
        var o = DownloadOptions()
        o.kind = MediaKind(rawValue: d.string(forKey: Prefs.kind) ?? "") ?? o.kind
        o.resolution = Resolution(rawValue: d.integer(forKey: Prefs.resolution)) ?? o.resolution
        o.codec = VideoCodec(rawValue: d.string(forKey: Prefs.codec) ?? "") ?? o.codec
        o.container = VideoContainer(rawValue: d.string(forKey: Prefs.container) ?? "") ?? o.container
        o.prefer60fps = d.bool(forKey: Prefs.prefer60fps)
        o.audioFormat = AudioFormat(rawValue: d.string(forKey: Prefs.audioFormat) ?? "") ?? o.audioFormat
        o.audioBitrate = AudioBitrate(rawValue: d.integer(forKey: Prefs.audioBitrate)) ?? o.audioBitrate
        return o
    }

    var isAudio: Bool { kind == .audio }

    var symbol: String { isAudio ? "waveform" : (resolution == .best ? "sparkles" : "film") }

    var label: String {
        if isAudio {
            var s = audioFormat.shortLabel
            if audioFormat.supportsBitrate, audioBitrate != .best { s += " \(audioBitrate.rawValue)k" }
            return s
        }
        var s = resolution.shortLabel
        if prefer60fps { s += "60" }
        if container != .mp4 { s += " · \(container.label)" }
        return s
    }

    var longLabel: String {
        if isAudio {
            return audioFormat.supportsBitrate ? "\(audioFormat.shortLabel) · \(audioBitrate.label)" : audioFormat.label
        }
        return label
    }

    var canEmbedThumbnail: Bool {
        isAudio ? audioFormat != .wav : container != .webm
    }

    var arguments: [String] {
        if isAudio {
            var args = ["-f", "ba/b", "-x"]
            if audioFormat != .original { args += ["--audio-format", audioFormat.rawValue] }
            // Prefer a source that needs no re-encode.
            if audioFormat == .m4a { args += ["-S", "acodec:aac"] }
            if audioFormat == .opus { args += ["-S", "acodec:opus"] }
            if audioFormat.supportsBitrate {
                args += ["--audio-quality", audioBitrate == .best ? "0" : "\(audioBitrate.rawValue)K"]
            }
            return args
        }

        var sort = [resolution == .best ? "res" : "res:\(resolution.rawValue)"]
        if prefer60fps { sort.append("fps") }
        switch container {
        case .webm:
            // WebM can only hold VP9/AV1 + Opus.
            sort.append("acodec:opus")
        case .mp4, .mkv:
            if codec == .compatible { sort += ["vcodec:h264", "acodec:aac"] }
        }
        var args = ["-f", "bv*+ba/b", "-S", sort.joined(separator: ","), "--merge-output-format", container.rawValue]
        // Also covers formats that arrive pre-merged. (H.264 can't go into WebM, so no remux there.)
        if container != .webm { args += ["--remux-video", container.rawValue] }
        return args
    }
}

// MARK: - Download item

@MainActor
@Observable
final class DownloadItem: Identifiable {
    enum State: Equatable {
        case queued, starting, downloading, processing, finished, failed, cancelled
    }

    let id = UUID()
    let url: String
    let options: DownloadOptions
    let folder: String

    var title: String
    var uploader: String?
    var duration: Double?
    var thumbnail: URL?

    /// Set when this item came from a Spotify link and is matched against YouTube Music.
    var spotify: SpotifyTrack?
    var resolvedURL: String?

    /// Set when the stream was found by loading the page ourselves (see PageSniffer).
    struct PageStream {
        let pageURL: String
        let userAgent: String?
        /// Raw streams are named after the page; embeds and rewritten links keep yt-dlp's own title.
        var usePageTitle = true
    }
    var pageStream: PageStream?
    var triedPageSearch = false

    var state: State = .queued
    var progress: Double = 0
    var speed: Double?
    var eta: Double?
    var phase: String?
    var fileURL: URL?
    var fileSize: Int64?
    var errorMessage: String?

    @ObservationIgnored var process: Process?

    init(url: String, options: DownloadOptions, folder: String) {
        self.url = url
        self.options = options
        self.folder = folder
        let host = URL(string: url)?.host(percentEncoded: false) ?? url
        self.title = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    convenience init(spotify track: SpotifyTrack, options: DownloadOptions, folder: String) {
        self.init(url: track.url, options: options, folder: folder)
        self.spotify = track
        self.title = track.title
        self.uploader = track.artists.joined(separator: ", ")
        self.duration = track.duration
        self.thumbnail = track.cover
    }

    var isActive: Bool {
        state == .queued || state == .starting || state == .downloading || state == .processing
    }

    var isRunning: Bool {
        state == .starting || state == .downloading || state == .processing
    }

    func reset() {
        state = .queued
        progress = 0
        speed = nil
        eta = nil
        phase = nil
        fileURL = nil
        fileSize = nil
        errorMessage = nil
    }
}
