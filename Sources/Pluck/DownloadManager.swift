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
    static let cookiesBrowser = "cookiesBrowser"
    static let notify = "notify"
    static let ytdlpPath = "ytdlpPath"
    static let autoUpdate = "autoUpdate"
    static let nightly = "nightly"
    static let askLocation = "askLocation"
    static let appAutoUpdate = "appAutoUpdate"
    static let showMenuBarIcon = "showMenuBarIcon"
    static let globalShortcut = "globalShortcut"
    static let startInMenuBar = "startInMenuBar"

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
            cookiesBrowser: "none",
            notify: true,
            ytdlpPath: "",
            autoUpdate: true,
            nightly: false,
            askLocation: false,
            appAutoUpdate: true,
            showMenuBarIcon: true,
            globalShortcut: true,
            startInMenuBar: false,
        ])
    }
}

@MainActor
@Observable
final class DownloadManager {
    var items: [DownloadItem] = []
    var ytdlpVersion: String?
    /// A link handed over by a pluck:// URL, waiting in the link field for the user to confirm.
    var pendingLink: String?

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
        items = History.load()
    }

    /// Saves finished, failed and cancelled downloads so the list survives a restart.
    func saveHistory(includingActive: Bool = false) {
        History.save(includingActive ? items : items.filter { !$0.isActive })
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
        // Pluck's static ffmpeg doesn't use the macOS keychain for HTTPS certificates; without a
        // bundle it can't fetch anything itself (clips, some streams). Use the system's.
        if env["SSL_CERT_FILE"] == nil, FileManager.default.fileExists(atPath: "/etc/ssl/cert.pem") {
            env["SSL_CERT_FILE"] = "/etc/ssl/cert.pem"
        }
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
    func add(_ urls: [String], options: DownloadOptions = .current, folder override: String? = nil, clip: ClipRange? = nil) {
        guard !urls.isEmpty else { return }
        var folder = override ?? defaults.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory()
        if override == nil, defaults.bool(forKey: Prefs.askLocation) {
            guard let chosen = askForFolder(starting: folder, count: urls.count) else { return }
            folder = chosen
        }
        for url in urls {
            if Playlists.looksLikePlaylist(url) {
                presentPicker(for: url, options: options, folder: folder)
            } else if Spotify.isSpotify(url) {
                addSpotify(url, options: options, folder: folder, clip: clip)
            } else {
                let item = DownloadItem(url: url, options: options, folder: folder)
                item.clip = clip
                items.insert(item, at: 0)
            }
        }
        pump()
    }

    func add(_ url: String, options: DownloadOptions = .current, folder: String? = nil, clip: ClipRange? = nil) {
        add([url], options: options, folder: folder, clip: clip)
    }

    private func askForFolder(starting path: String, count: Int) -> String? {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: path)
        panel.prompt = String(localized: "Download Here")
        panel.message = count == 1 ? String(localized: "Choose where to save this download.") : String(localized: "Choose where to save these \(count) downloads.")
        NSApp.activate()
        return panel.runModal() == .OK ? panel.url?.path : nil
    }

    // MARK: - Playlist picker

    /// Playlist links waiting for the user to choose videos; the first one is shown.
    var picks: [PlaylistPick] = []

    private func presentPicker(for url: String, options: DownloadOptions, folder: String) {
        let pick = PlaylistPick(sourceURL: url, folder: folder, options: options)
        picks.append(pick)
        AppDelegate.openMainWindow?()
        Task { await load(pick) }
    }

    private func load(_ pick: PlaylistPick) async {
        if let link = Spotify.parse(pick.sourceURL) {
            do {
                let collection = try await Spotify.fetch(link)
                pick.title = collection.name
                pick.owner = String(localized: "Spotify \(link.kind.rawValue)")
                pick.entries = collection.tracks.map { track in
                    PlaylistEntry(id: track.id, url: track.url, title: track.title,
                                  subtitle: track.artists.joined(separator: ", "),
                                  duration: track.duration, thumbnail: track.cover, spotify: track)
                }
            } catch {
                pick.phase = .failed(error.localizedDescription)
                return
            }
        } else {
            let args = ["--flat-playlist", "--dump-single-json", "--no-warnings", "--yes-playlist",
                        "--playlist-end", "\(Playlists.limit)"] + cookieArguments() + ["--", pick.sourceURL]
            guard let data = await capture(args), let playlist = Playlists.parse(data) else {
                // Not a playlist after all, or unreadable: download the link as a single video.
                cancelPick(pick)
                items.insert(DownloadItem(url: pick.sourceURL, options: pick.options, folder: pick.folder), at: 0)
                pump()
                return
            }
            pick.title = playlist.title ?? String(localized: "Playlist")
            pick.owner = playlist.owner
            pick.entries = playlist.entries
            pick.hiddenCount = playlist.hidden
        }

        // A video link inside a playlist starts with just that video; a playlist link with everything.
        if let focus = Playlists.focusedVideoID(in: pick.sourceURL), pick.entries.contains(where: { $0.id == focus }) {
            pick.selected = [focus]
        } else {
            pick.selectAll()
        }
        pick.phase = pick.entries.isEmpty ? .failed(String(localized: "This playlist has no videos Pluck can download.")) : .ready
    }

    func cancelPick(_ pick: PlaylistPick) {
        picks.removeAll { $0.id == pick.id }
    }

    /// Queues the chosen entries, in playlist order.
    func confirm(_ pick: PlaylistPick) {
        // Uses the format picked in the sheet (stored like the main window's choice).
        var options = DownloadOptions.current
        let spotifyItems = pick.selectedEntries.contains { $0.spotify != nil }
        if spotifyItems { options.kind = .audio }
        let newItems = pick.selectedEntries.map { entry -> DownloadItem in
            let item: DownloadItem
            if let track = entry.spotify {
                item = DownloadItem(spotify: track, options: options, folder: pick.folder)
            } else {
                item = DownloadItem(url: entry.url, options: options, folder: pick.folder)
                item.title = entry.title
                item.uploader = entry.subtitle
                item.duration = entry.duration
                item.thumbnail = entry.thumbnail
            }
            return item
        }
        // Newest first in the list, so the playlist's first video ends up at the top of the batch.
        items.insert(contentsOf: newItems, at: 0)
        cancelPick(pick)
        pump()
    }

    private func cookieArguments() -> [String] {
        guard let browser = CookieBrowser(rawValue: defaults.string(forKey: Prefs.cookiesBrowser) ?? ""),
              browser.isInstalled, let value = browser.argument else { return [] }
        return ["--cookies-from-browser", value]
    }

    private func addSpotify(_ url: String, options: DownloadOptions, folder: String, clip: ClipRange? = nil) {
        // Spotify is always audio; keep the chosen audio format even if video is selected.
        var audio = options
        audio.kind = .audio

        let placeholder = DownloadItem(url: url, options: audio, folder: folder)
        placeholder.title = "Spotify"
        placeholder.state = .starting
        placeholder.phase = String(localized: "Reading Spotify link…")
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
                let tracks = collection.tracks.map { track in
                    let item = DownloadItem(spotify: track, options: audio, folder: folder)
                    item.clip = clip
                    return item
                }
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
        saveHistory()
    }

    func retry(_ item: DownloadItem) {
        if item.spotify == nil, Spotify.isSpotify(item.url) {
            // A Spotify link that failed before its tracks were read.
            guard let index = items.firstIndex(where: { $0.id == item.id }) else { return }
            items.remove(at: index)
            addSpotify(item.url, options: item.options, folder: item.folder, clip: item.clip)
            return
        }
        item.reset()
        item.triedPageSearch = false
        if item.pageStream != nil {
            item.pageStream = nil
            item.resolvedURL = nil
        }
        pump()
    }

    func remove(_ item: DownloadItem) {
        cancel(item)
        items.removeAll { $0.id == item.id }
        saveHistory()
    }

    func clearFinished() {
        items.removeAll { !$0.isActive }
        saveHistory()
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
        saveHistory()
    }

    /// Called when Pluck quits: remembers unfinished downloads (as interrupted) and stops yt-dlp,
    /// which would otherwise keep running in the background with nothing watching it.
    func shutDown() {
        saveHistory(includingActive: true)
        for item in items { item.process?.terminate() }
    }

    // MARK: - Running

    private func arguments(for item: DownloadItem, url: String) -> [String] {
        let options = item.options
        var args = [
            "--newline", "--progress", "--no-simulate",
            "--progress-template",
            "download:PLUCK|%(progress.status)s|%(progress.downloaded_bytes)s|%(progress.total_bytes)s|%(progress.total_bytes_estimate)s|%(progress.speed)s|%(progress.eta)s",
            "--progress-template", "postprocess:PLUCKPP|%(progress.postprocessor)s",
            "--print", "video:PLUCKMETA %(.{title,uploader,channel,duration,thumbnail,acodec,abr})j",
            "--print", "after_move:PLUCKFILE %(filepath)s",
            "-P", item.folder,
        ]
        args += options.arguments
        // Only download part of the video; cut exactly at the chosen times.
        let clipSuffix = item.clip?.fileSuffix ?? ""
        if let clip = item.clip {
            args += ["--download-sections", clip.sectionArgument, "--force-keyframes-at-cuts"]
        }

        if let stream = item.pageStream {
            // A raw stream found on the page: send the page as referer and name it after the page.
            args += ["--referer", stream.pageURL, "--no-playlist", "-o", "%(title)s\(clipSuffix).%(ext)s"]
            if let agent = stream.userAgent { args += ["--user-agent", agent] }
            if stream.usePageTitle {
                args += ["--parse-metadata", "\(Spotify.metadataLiteral(item.title)):%(title)s"]
            }
            if defaults.bool(forKey: Prefs.embedThumbnail), options.canEmbedThumbnail { args.append("--embed-thumbnail") }
            if defaults.bool(forKey: Prefs.embedMetadata) { args.append("--embed-metadata") }
        } else if let track = item.spotify {
            // Tag the file with Spotify's metadata rather than YouTube's.
            let artist = track.artists.joined(separator: ", ")
            args += ["--parse-metadata", "\(Spotify.metadataLiteral(track.title)):%(title)s"]
            args += ["--parse-metadata", "\(Spotify.metadataLiteral(artist)):%(artist)s"]
            if let album = track.album {
                args += ["--parse-metadata", "\(Spotify.metadataLiteral(album)):%(album)s"]
            }
            args += ["-o", "%(artist)s - %(title)s\(clipSuffix).%(ext)s", "--no-playlist", "--embed-metadata"]
            if options.canEmbedThumbnail {
                // YouTube Music art is 16:9 with bars; crop it to a square cover.
                args += ["--embed-thumbnail", "--convert-thumbnails", "jpg",
                         "--ppa", "ThumbnailsConvertor+FFmpeg_o:-c:v mjpeg -vf crop=\"'if(gt(ih,iw),iw,ih)':'if(gt(iw,ih),ih,iw)'\""]
            }
        } else {
            args += ["-o", "%(title)s\(clipSuffix).%(ext)s"]
            // Playlists go through the picker, so a link here always means one video.
            args.append("--no-playlist")
            if defaults.bool(forKey: Prefs.embedMetadata) { args.append("--embed-metadata") }
            if defaults.bool(forKey: Prefs.embedThumbnail), options.canEmbedThumbnail { args.append("--embed-thumbnail") }
            if defaults.bool(forKey: Prefs.embedSubtitles), !options.isAudio {
                args += ["--write-subs", "--embed-subs", "--sub-langs", "all,-live_chat"]
            }
            if defaults.bool(forKey: Prefs.removeSponsors) { args += ["--sponsorblock-remove", "sponsor"] }
        }

        // A raw stream found by loading a page is a link that page chose. Never send the user's
        // browser cookies along with it (the page was loaded logged out anyway).
        let isPageStream = item.pageStream?.usePageTitle == true
        if !isPageStream { args += cookieArguments() }
        args += ["--", url]
        return args
    }

    private func start(_ item: DownloadItem) {
        item.state = .starting
        guard executableURL != nil else {
            fail(item, String(localized: "yt-dlp not found. Install it with “brew install yt-dlp” or set its path in Settings."))
            return
        }

        if let track = item.spotify, item.resolvedURL == nil {
            item.phase = String(localized: "Finding on YouTube Music…")
            Task {
                let match = await findMatch(for: track)
                guard item.state == .starting else { return }
                if let match {
                    item.resolvedURL = match
                    launch(item)
                } else {
                    fail(item, String(localized: "Couldn’t find this song on YouTube Music."))
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

        let errors = Task.detached {
            for await line in PipeLines.stream(err.fileHandleForReading) where line.hasPrefix("ERROR:") {
                // "ERROR: [youtube] abc123: Video unavailable" → "Video unavailable"
                var message = line
                    .replacingOccurrences(of: "ERROR: ", with: "")
                    .replacingOccurrences(of: #"^\[[^\]]+\] [^:]+: "#, with: "", options: .regularExpression)
                if message.localizedCaseInsensitiveContains("cookies database")
                    || message.localizedCaseInsensitiveContains("decrypt") {
                    message = String(localized: "Couldn’t read this browser’s cookies. Pick another browser (or None) in Settings → Advanced.")
                }
                let lower = message.lowercased()
                if lower.contains("logged-in") || lower.contains("login required") || lower.contains("log in to")
                    || (lower.contains("--cookies") && !lower.contains("cookies database")) {
                    message = String(localized: "This site needs you to be logged in. Log in with your browser, then choose that browser under Settings → Advanced → Use cookies from.")
                } else if lower.contains("drm protected") {
                    message = String(localized: "This video is DRM-protected and can’t be downloaded.")
                }
                let final = message
                await MainActor.run { item.errorMessage = final }
            }
        }
        Task.detached {
            for await line in PipeLines.stream(out.fileHandleForReading) {
                await self.handle(line, for: item)
            }
            process.waitUntilExit()
            // Let the error text land before deciding what to do next.
            await errors.value
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
            if item.options.isAudio {
                item.sourceAudio = Self.describeAudio(codec: meta["acodec"] as? String, bitrate: meta["abr"] as? Double)
            }
            // ffmpeg cuts clips without reporting progress; say what's happening meanwhile.
            if item.clip != nil, item.state == .starting { item.phase = String(localized: "Cutting clip…") }
            // Spotify items keep their own title, artist and length.
            guard item.spotify == nil else { return }
            if let t = meta["title"] as? String { item.title = t }
            item.uploader = (meta["uploader"] as? String) ?? (meta["channel"] as? String)
            item.duration = meta["duration"] as? Double
        } else if line.hasPrefix("PLUCKFILE ") {
            item.fileURL = URL(fileURLWithPath: String(line.dropFirst("PLUCKFILE ".count)))
        }
    }

    /// "Opus 272 kbps", "AAC 256 kbps"… from yt-dlp's codec id and average bitrate.
    static func describeAudio(codec: String?, bitrate: Double?) -> String? {
        guard let codec = codec?.lowercased(), codec != "none" else { return nil }
        let name = switch codec {
        case let c where c.hasPrefix("mp4a") || c == "aac": "AAC"
        case let c where c.hasPrefix("opus"): "Opus"
        case let c where c.hasPrefix("vorbis"): "Vorbis"
        case let c where c.hasPrefix("mp3"): "MP3"
        case let c where c.hasPrefix("flac"): "FLAC"
        case let c where c.hasPrefix("alac"): "ALAC"
        default: codec.uppercased()
        }
        guard let bitrate, bitrate > 0 else { return name }
        return "\(name) \(Int(bitrate.rounded())) kbps"
    }

    private static func describe(postprocessor: String) -> String {
        switch postprocessor {
        case "Merger": String(localized: "Merging audio & video…")
        case "ExtractAudio": String(localized: "Converting audio…")
        case "EmbedThumbnail", "ThumbnailsConvertor": String(localized: "Embedding artwork…")
        case "FFmpegMetadata", "Metadata", "MetadataParser": String(localized: "Writing metadata…")
        case "EmbedSubtitle": String(localized: "Embedding subtitles…")
        case "SponsorBlock", "ModifyChapters": String(localized: "Removing sponsors…")
        default: String(localized: "Finishing up…")
        }
    }

    private func finish(_ item: DownloadItem, status: Int32) {
        item.process = nil
        guard item.state != .cancelled else { pump(); return }

        if status != 0, shouldSearchPage(item) {
            searchPage(for: item)
            return
        }
        defer { pump() }

        defer { saveHistory() }
        if status == 0 {
            item.state = .finished
            item.finishedAt = .now
            item.progress = 1
            if let file = item.fileURL,
               let size = try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64 {
                item.fileSize = size
            }
            batchFinished.append(item.title)
        } else {
            item.state = .failed
            if item.errorMessage == nil { item.errorMessage = String(localized: "yt-dlp exited with code \(status).") }
            batchFailed += 1
        }

        guard !items.contains(where: { $0.isActive && $0.id != item.id }) else { return }
        switch (batchFinished.count, batchFailed) {
        case (1, 0): notify(title: String(localized: "Download complete"), body: batchFinished[0])
        case (let ok, 0): notify(title: String(localized: "Downloads complete"), body: String(localized: "\(ok) files saved"))
        case (0, 1): notify(title: String(localized: "Download failed"), body: item.title)
        case (let ok, let bad): notify(title: String(localized: "Downloads finished"), body: String(localized: "\(ok) saved, \(bad) failed"))
        }
        batchFinished = []
        batchFailed = 0
    }

    // MARK: - Page fallback

    /// Sites yt-dlp has a dedicated extractor for are left alone; so are login/cookie problems,
    /// which a fresh, logged-out web view can't fix.
    private func shouldSearchPage(_ item: DownloadItem) -> Bool {
        guard !item.triedPageSearch, item.spotify == nil, item.pageStream == nil,
              let host = URL(string: item.url)?.host?.lowercased() else { return false }
        let skip = ["youtube.com", "youtu.be", "spotify.com"]
        if skip.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) { return false }
        let message = item.errorMessage?.lowercased() ?? ""
        return !["cookies", "logged-in", "log in", "login", "drm"].contains { message.contains($0) }
    }

    private func searchPage(for item: DownloadItem) {
        guard let url = URL(string: item.url) else { return }
        let originalError = item.errorMessage
        item.triedPageSearch = true
        item.state = .starting
        item.errorMessage = nil
        item.phase = String(localized: "Looking for a video on the page…")

        Task {
            let sniffer = PageSniffer()
            let result = await sniffer.sniff(url)
            guard item.state == .starting else { return }
            guard let result else {
                fail(item, originalError.map { String(localized: "\($0) No playable video was found on the page either.") }
                     ?? String(localized: "No playable video was found on this page."))
                return
            }
            if let title = result.title { item.title = title }
            if item.thumbnail == nil { item.thumbnail = result.thumbnail }
            item.pageStream = .init(pageURL: item.url, userAgent: result.isEmbed ? nil : result.userAgent,
                                    usePageTitle: !result.isEmbed)
            item.resolvedURL = result.mediaURL.absoluteString
            item.phase = nil
            launch(item)
        }
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

/// Lines from a pipe as they arrive. This deliberately avoids `FileHandle.bytes`: two of those
/// reading at once (yt-dlp's stdout and stderr) block each other, so progress only reached the
/// app when yt-dlp exited. `readabilityHandler` reads each pipe independently.
enum PipeLines {
    private final class Buffer: @unchecked Sendable { var data = Data() }

    static func stream(_ handle: FileHandle) -> AsyncStream<String> {
        AsyncStream { continuation in
            let buffer = Buffer()
            handle.readabilityHandler = { handle in
                let chunk = handle.availableData
                guard !chunk.isEmpty else {
                    if !buffer.data.isEmpty { continuation.yield(String(decoding: buffer.data, as: UTF8.self)) }
                    handle.readabilityHandler = nil
                    continuation.finish()
                    return
                }
                buffer.data.append(chunk)
                while let newline = buffer.data.firstIndex(of: 0x0A) {
                    var line = buffer.data[buffer.data.startIndex..<newline]
                    if line.last == 0x0D { line = line.dropLast() }
                    continuation.yield(String(decoding: line, as: UTF8.self))
                    buffer.data.removeSubrange(buffer.data.startIndex...newline)
                }
            }
        }
    }
}
