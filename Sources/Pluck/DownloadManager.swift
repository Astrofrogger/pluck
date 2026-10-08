import AppKit
import Foundation
import Observation
import UserNotifications

enum Prefs {
    static let downloadPath = "downloadPath"
    static let kind = "kind"
    static let resolution = "resolution"
    static let codec = "codec"
    static let container = "container"
    static let prefer60fps = "prefer60fps"
    static let audioFormat = "audioFormat"
    static let audioBitrate = "audioBitrate"
    static let maxConcurrent = "maxConcurrent"
    static let embedMetadata = "embedMetadata"
    static let embedThumbnail = "embedThumbnail"
    static let embedSubtitles = "embedSubtitles"
    static let removeSponsors = "removeSponsors"
    static let allowPlaylists = "allowPlaylists"
    static let cookiesBrowser = "cookiesBrowser"
    static let notify = "notify"
    static let ytdlpPath = "ytdlpPath"
    static let autoUpdate = "autoUpdate"
    static let nightly = "nightly"
    static let askLocation = "askLocation"
    static let appAutoUpdate = "appAutoUpdate"

    static func registerDefaults() {
        UserDefaults.standard.register(defaults: [
            downloadPath: FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0].path,
            kind: MediaKind.video.rawValue,
            resolution: Resolution.best.rawValue,
            codec: VideoCodec.compatible.rawValue,
            container: VideoContainer.mp4.rawValue,
            prefer60fps: false,
            audioFormat: AudioFormat.m4a.rawValue,
            audioBitrate: AudioBitrate.best.rawValue,
            maxConcurrent: 3,
            embedMetadata: true,
            embedThumbnail: true,
            embedSubtitles: false,
            removeSponsors: false,
            allowPlaylists: false,
            cookiesBrowser: "none",
            notify: true,
            ytdlpPath: "",
            autoUpdate: true,
            nightly: false,
            askLocation: false,
            appAutoUpdate: true,
        ])
    }
}

@MainActor
@Observable
final class DownloadManager {
    var items: [DownloadItem] = []
    var ytdlpVersion: String?
    /// True while Pluck is downloading or updating its own yt-dlp/ffmpeg.
    var toolsInstalling = false

    /// Results since the queue was last empty, for one summary notification per batch.
    private var batchFinished: [String] = []
    private var batchFailed = 0

    private let defaults = UserDefaults.standard

    init() {
        Prefs.registerDefaults()
        if Bundle.main.bundleIdentifier != nil {
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        refreshVersion()
    }

    var activeCount: Int { items.filter(\.isActive).count }
    var hasFinished: Bool { items.contains { !$0.isActive } }

    // MARK: - Locating yt-dlp

    nonisolated static let searchPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin", "/usr/bin"]

    var executableURL: URL? {
        let custom = defaults.string(forKey: Prefs.ytdlpPath) ?? ""
        if !custom.isEmpty, FileManager.default.isExecutableFile(atPath: custom) {
            return URL(fileURLWithPath: custom)
        }
        if defaults.bool(forKey: Prefs.autoUpdate), Updater.isInstalled {
            return Updater.binaryURL
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        for dir in Self.searchPaths + ["\(home)/.local/bin"] {
            let path = "\(dir)/yt-dlp"
            if FileManager.default.isExecutableFile(atPath: path) { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    /// yt-dlp needs ffmpeg to merge video and audio and to convert audio.
    var ffmpegMissing: Bool {
        !toolDirectories.contains { FileManager.default.isExecutableFile(atPath: "\($0)/ffmpeg") }
    }

    /// Pluck's own tools come first when auto-update is on, then the usual install locations.
    private var toolDirectories: [String] {
        (defaults.bool(forKey: Prefs.autoUpdate) ? [Updater.directory.path] : []) + Self.searchPaths
    }

    /// Apps launched from Finder get a minimal PATH, so add the usual places ffmpeg lives.
    private var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        let existing = env["PATH"] ?? "/usr/bin:/bin"
        env["PATH"] = (toolDirectories + [existing]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        return env
    }

    func refreshVersion() {
        Task {
            let data = await capture(["--version"])
            let version = data.map { String(decoding: $0, as: UTF8.self) }?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ytdlpVersion = (version?.isEmpty ?? true) ? nil : version
        }
    }

    /// Runs yt-dlp to completion and returns stdout, or nil if it couldn't run or failed.
    private func capture(_ arguments: [String]) async -> Data? {
        guard let exe = executableURL else { return nil }
        let env = environment
        return await Task.detached {
            let p = Process()
            p.executableURL = exe
            p.arguments = arguments
            p.environment = env
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return p.terminationStatus == 0 ? data : nil
        }.value
    }

    // MARK: - Queue

    /// Adds downloads for one or more links. When "Ask where to save" is on, asks once for the batch.
    func add(_ urls: [String], options: DownloadOptions = .current, folder override: String? = nil) {
        guard !urls.isEmpty else { return }
        var folder = override ?? defaults.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory()
        if override == nil, defaults.bool(forKey: Prefs.askLocation) {
            guard let chosen = askForFolder(starting: folder, count: urls.count) else { return }
            folder = chosen
        }
        for url in urls {
            if Spotify.isSpotify(url) {
                addSpotify(url, options: options, folder: folder)
            } else {
                items.insert(DownloadItem(url: url, options: options, folder: folder), at: 0)
            }
        }
        pump()
    }

    func add(_ url: String, options: DownloadOptions = .current, folder: String? = nil) {
        add([url], options: options, folder: folder)
    }

    private func askForFolder(starting path: String, count: Int) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.prompt = "Download Here"
        panel.message = count == 1 ? "Choose where to save this download." : "Choose where to save these \(count) downloads."
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    private func addSpotify(_ url: String, options: DownloadOptions, folder: String) {
        // Spotify is always audio; keep the chosen audio format even if video is selected.
        var audio = options
        audio.kind = .audio

        let placeholder = DownloadItem(url: url, options: audio, folder: folder)
        placeholder.title = "Spotify"
        placeholder.state = .starting
        placeholder.phase = "Reading Spotify link…"
        items.insert(placeholder, at: 0)

        guard let link = Spotify.parse(url) else {
            fail(placeholder, Spotify.Failure.unsupported.localizedDescription)
            return
        }

        Task {
            do {
                let collection = try await Spotify.fetch(link)
                guard placeholder.state != .cancelled,
                      let index = items.firstIndex(where: { $0.id == placeholder.id }) else { return }
                let tracks = collection.tracks.map { DownloadItem(spotify: $0, options: audio, folder: folder) }
                items.replaceSubrange(index...index, with: tracks)
                pump()
            } catch {
                fail(placeholder, error.localizedDescription)
            }
        }
    }

    func cancel(_ item: DownloadItem) {
        guard item.isActive else { return }
        item.state = .cancelled
        item.process?.terminate()
        pump()
    }

    func retry(_ item: DownloadItem) {
        if item.spotify == nil, Spotify.isSpotify(item.url) {
            // A Spotify link that failed before its tracks were read.
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items.remove(at: index)
            addSpotify(item.url, options: item.options, folder: item.folder)
            return
        }
        item.reset()
        pump()
    }

    func remove(_ item: DownloadItem) {
        cancel(item)
        items.removeAll { $0.id == item.id }
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
    }

    /// Starts queued items, oldest first, up to the concurrency limit.
    func pump() {
        // On first launch, wait for Pluck to finish fetching yt-dlp/ffmpeg instead of failing.
        if toolsInstalling, executableURL == nil || ffmpegMissing {
            updateBadge()
            return
        }
        let limit = max(1, defaults.integer(forKey: Prefs.maxConcurrent))
        var running = items.filter(\.isRunning).count
        for item in items.reversed() where item.state == .queued && running < limit {
            running += 1
            start(item)
        }
        updateBadge()
    }

    private func fail(_ item: DownloadItem, _ message: String) {
        item.state = .failed
        item.errorMessage = message
        pump()
    }

    // MARK: - Running

    private func arguments(for item: DownloadItem, url: String) -> [String] {
        let options = item.options
        var args = [
            "--newline", "--progress", "--no-simulate",
            "--progress-template",
            "download:PLUCK|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:PLUCKPP|%(progress.postprocessor)s",
            "--print", "video:PLUCKMETA %(.{title,uploader,channel,duration,thumbnail})j",
            "--print", "after_move:PLUCKFILE %(filepath)s",
            "-P", item.folder,
        ]
        args += options.arguments

        if let track = item.spotify {
            // Tag the file with Spotify's metadata rather than YouTube's.
            let artist = track.artists.joined(separator: ", ")
            args += ["--parse-metadata", "\(Spotify.metadataLiteral(track.title)):%(title)s"]
            args += ["--parse-metadata", "\(Spotify.metadataLiteral(artist)):%(artist)s"]
            if let album = track.album {
                args += ["--parse-metadata", "\(Spotify.metadataLiteral(album)):%(album)s"]
            }
            args += ["-o", "%(artist)s - %(title)s.%(ext)s", "--no-playlist", "--embed-metadata"]
            if options.canEmbedThumbnail {
                // YouTube Music art is 16:9 with bars; crop it to a square cover.
                args += ["--embed-thumbnail", "--convert-thumbnails", "jpg",
                         "--ppa", "ThumbnailsConvertor+FFmpeg_o:-c:v mjpeg -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\""]
            }
        } else {
            args += ["-o", "%(title)s.%(ext)s"]
            args.append(defaults.bool(forKey: Prefs.allowPlaylists) ? "--yes-playlist" : "--no-playlist")
            if defaults.bool(forKey: Prefs.embedMetadata) { args.append("--embed-metadata") }
            if defaults.bool(forKey: Prefs.embedThumbnail), options.canEmbedThumbnail { args.append("--embed-thumbnail") }
            if defaults.bool(forKey: Prefs.embedSubtitles), !options.isAudio {
                args += ["--write-subs", "--embed-subs", "--sub-langs", "all,-live_chat"]
            }
            if defaults.bool(forKey: Prefs.removeSponsors) { args += ["--sponsorblock-remove", "sponsor"] }
        }

        if let browser = CookieBrowser(rawValue: defaults.string(forKey: Prefs.cookiesBrowser) ?? ""),
           browser.isInstalled, let value = browser.argument {
            args += ["--cookies-from-browser", value]
        }
        args += ["--", url]
        return args
    }

    private func start(_ item: DownloadItem) {
        item.state = .starting
        guard executableURL != nil else {
            fail(item, "yt-dlp not found. Install it with “brew install yt-dlp” or set its path in Settings.")
            return
        }

        if let track = item.spotify, item.resolvedURL == nil {
            item.phase = "Finding on YouTube Music…"
            Task {
                let match = await findMatch(for: track)
                guard item.state == .starting else { return }
                if let match {
                    item.resolvedURL = match
                    launch(item)
                } else {
                    fail(item, "Couldn’t find this song on YouTube Music.")
                }
            }
            return
        }
        launch(item)
    }

    /// Finds the best YouTube source for a Spotify track: the top YouTube Music song result when its
    /// title matches, otherwise the YouTube video whose title matches and length is closest.
    private func findMatch(for track: SpotifyTrack) async -> String? {
        let flat = ["--flat-playlist", "--dump-single-json", "--no-warnings"]

        if let data = await capture(flat + ["--playlist-items", "1:5", Spotify.musicSearchURL(for: track)]),
           let entries = Self.entries(data),
           let hit = entries.first(where: { Spotify.titlesMatch($0["title"] as? String ?? "", track) }),
           let url = hit["url"] as? String {
            return url
        }

        guard let data = await capture(flat + [Spotify.videoSearchQuery(for: track)]),
              let entries = Self.entries(data), !entries.isEmpty else { return nil }
        let target = track.duration ?? 0
        let scored = entries.compactMap { e -> (url: String, score: Double)? in
            guard let url = e["url"] as? String else { return nil }
            var score = 0.0
            if Spotify.titlesMatch(e["title"] as? String ?? "", track) { score += 100 }
            if let d = e["duration"] as? Double, target > 0 { score -= min(abs(d - target), 60) }
            return (url, score)
        }
        return scored.max { $0.score < $1.score }?.url
    }

    private nonisolated static func entries(_ data: Data) -> [[String: Any]]? {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["entries"] as? [[String: Any]]
    }

    private func launch(_ item: DownloadItem) {
        guard let exe = executableURL else { return }
        let process = Process()
        process.executableURL = exe
        process.arguments = arguments(for: item, url: item.resolvedURL ?? item.url)
        process.environment = environment
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        item.process = process

        do {
            try process.run()
        } catch {
            fail(item, error.localizedDescription)
            return
        }

        Task.detached {
            do {
                for try await line in err.fileHandleForReading.bytes.lines where line.hasPrefix("ERROR:") {
                    // "ERROR: [youtube] abc123: Video unavailable" → "Video unavailable"
                    var message = line
                        .replacingOccurrences(of: "ERROR: ", with: "")
                        .replacingOccurrences(of: #"^\[[^\]]+\] [^:]+: "#, with: "", options: .regularExpression)
                    if message.localizedCaseInsensitiveContains("cookies database")
                        || message.localizedCaseInsensitiveContains("decrypt") {
                        message = "Couldn’t read this browser’s cookies. Pick another browser (or None) in Settings → Advanced."
                    }
                    let final = message
                    await MainActor.run { item.errorMessage = final }
                }
            } catch {}
        }
        Task.detached {
            do {
                for try await line in out.fileHandleForReading.bytes.lines {
                    await self.handle(line, for: item)
                }
            } catch {}
            process.waitUntilExit()
            await self.finish(item, status: process.terminationStatus)
        }
    }

    private func handle(_ line: String, for item: DownloadItem) {
        guard item.state != .cancelled else { return }

        if line.hasPrefix("PLUCK|") {
            let f = line.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
            guard f.count >= 7 else { return }
            let done = Double(f[2]) ?? 0
            let total = Double(f[3]) ?? Double(f[4]) ?? 0
            if total > 0 { item.progress = min(done / total, 1) }
            item.speed = Double(f[5])
            item.eta = Double(f[6])
            item.state = .downloading
        } else if line.hasPrefix("PLUCKPP|") {
            item.state = .processing
            item.phase = Self.describe(postprocessor: String(line.dropFirst("PLUCKPP|".count)))
        } else if line.hasPrefix("PLUCKMETA ") {
            let json = Data(line.dropFirst("PLUCKMETA ".count).utf8)
            guard let meta = try? JSONSerialization.jsonObject(with: json) as? [String: Any] else { return }
            if item.thumbnail == nil, let thumb = meta["thumbnail"] as? String { item.thumbnail = URL(string: thumb) }
            // Spotify items keep their own title, artist and length.
            guard item.spotify == nil else { return }
            if let t = meta["title"] as? String { item.title = t }
            item.uploader = (meta["uploader"] as? String) ?? (meta["channel"] as? String)
            item.duration = meta["duration"] as? Double
        } else if line.hasPrefix("PLUCKFILE ") {
            item.fileURL = URL(fileURLWithPath: String(line.dropFirst("PLUCKFILE ".count)))
        }
    }

    private static func describe(postprocessor: String) -> String {
        switch postprocessor {
        case "Merger": "Merging audio & video…"
        case "ExtractAudio": "Converting audio…"
        case "EmbedThumbnail", "ThumbnailsConvertor": "Embedding artwork…"
        case "FFmpegMetadata", "Metadata", "MetadataParser": "Writing metadata…"
        case "EmbedSubtitle": "Embedding subtitles…"
        case "SponsorBlock", "ModifyChapters": "Removing sponsors…"
        default: "Finishing up…"
        }
    }

    private func finish(_ item: DownloadItem, status: Int32) {
        item.process = nil
        defer { pump() }
        guard item.state != .cancelled else { return }

        if status == 0 {
            item.state = .finished
            item.progress = 1
            if let file = item.fileURL,
               let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 {
                item.fileSize = size
            }
            batchFinished.append(item.title)
        } else {
            item.state = .failed
            if item.errorMessage == nil { item.errorMessage = "yt-dlp exited with code \(status)." }
            batchFailed += 1
        }

        guard !items.contains(where: { $0.isActive && $0.id != item.id }) else { return }
        switch (batchFinished.count, batchFailed) {
        case (1, 0): notify(title: "Download complete", body: batchFinished[0])
        case (let ok, 0): notify(title: "Downloads complete", body: "\(ok) files saved")
        case (0, 1): notify(title: "Download failed", body: item.title)
        case (let ok, let bad): notify(title: "Downloads finished", body: "\(ok) saved, \(bad) failed")
        }
        batchFinished = []
        batchFailed = 0
    }

    private func notify(title: String, body: String) {
        guard defaults.bool(forKey: Prefs.notify),
              Bundle.main.bundleIdentifier != nil,
              !NSApp.isActive else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    private func updateBadge() {
        let count = activeCount
        NSApp?.dockTile.badgeLabel = count > 0 ? "\(count)" : nil
    }
}
