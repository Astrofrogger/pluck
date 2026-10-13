import AVFoundation
import AppKit
import CryptoKit
import SwiftUI
import UniformTypeIdentifiers

/// A file opened in the Editor window.
struct EditorTarget: Codable, Hashable {
    var path: String
    var file: URL { URL(fileURLWithPath: path) }

    /// Videos and songs open in the Editor.
    static func canOpen(_ file: URL) -> Bool {
        guard let type = UTType(filenameExtension: file.pathExtension) else { return false }
        return type.conforms(to: .movie) || type.conforms(to: .audio)
    }
}

extension EditorTarget {
    /// Opens the file in the Editor: a tab of Pluck Studio's window, or the Editor window.
    @MainActor func open(_ openWindow: OpenWindowAction) {
        #if STUDIO
        StudioNavigator.shared.open(self)
        AppDelegate.openMainWindow?()
        #else
        openWindow(value: self)
        #endif
    }
}

/// What the Editor works with: the player, where the playhead is, the in and out points, and the
/// pictures and sound shown on the timeline.
@MainActor
@Observable
final class EditorModel {
    /// Local AI work running for this file, and what went wrong.
    @Observable
    final class Jobs {
        var finding = false
        var problem: String?
        var findingSpeakers = false
        var speakerProblem: String?
        var findingStory = false
        var storyProgress = 0.0
        var storyProblem: String?
        var translating = false
        var translateProblem: String?
    }

    let jobs = Jobs()
    let file: URL
    let player = AVPlayer()
    /// What this file exported, and the export running now.
    let exports = EditorExports()
    /// The subtitle line picked on the timeline or in the sidebar.
    var selectedSubtitle: UUID?
    /// Loaded once: the view can come and go (tabs, pages) without reading the file again.
    @ObservationIgnored private var loaded = false

    private(set) var duration: Double = 0
    private(set) var frameRate: Double = 25
    private(set) var hasVideo = false
    /// Width over height of the picture.
    private(set) var aspect: CGFloat = 16 / 9
    /// Where the playhead is (seconds).
    private(set) var time: Double = 0
    var inPoint: Double?
    var outPoint: Double?
    /// Plays the range over and over.
    var loop = false
    /// Thumbnails spread evenly over the file, for the filmstrip.
    private(set) var thumbnails: [CGImage?] = []
    /// The loudest moment in each slice of the file (0…1), for the waveform.
    private(set) var peaks: [Float] = []
    private(set) var rate: Float = 0
    private(set) var problem: String?
    /// Chapters, cuts, pauses, and what local AI found.
    var markers: [EditorMarker] = []
    /// Which kinds are shown (and snapped to).
    var shownKinds: Set<EditorMarker.Kind> = [.chapter, .cut, .silence, .moment, .filler, .story]
    /// The playhead and range edges jump to cuts, pauses and markers nearby (N).
    var snapping = true
    /// What's being looked for now ("Finding cuts…").
    private(set) var analysing: String?
    /// The tool the timeline works with, as in an editing program.
    enum Tool { case select, blade }
    var tool: Tool = .select
    /// Where the file is cut into parts (seconds, in order).
    var cuts: [Double] = []
    /// The parts taken out, by where they start.
    var removed: Set<Double> = []
    /// The parts selected on the timeline, by where they start.
    var selected: Set<Double> = []
    @ObservationIgnored var history: [(cuts: [Double], removed: Set<Double>)] = []
    /// Whether the file has sound (for exporting the edit).
    var hasAudio: Bool { !peaks.isEmpty }
    /// The picture's size in pixels (for subtitles burned in at the right size).
    private(set) var pixelSize = CGSize(width: 1920, height: 1080)
    /// What the player plays (the file, or a copy macOS can play).
    @ObservationIgnored var playedAsset: AVURLAsset?
    #if STUDIO
    /// The picture's settings (transform, crop, dynamic zoom…), as for a clip in a project.
    var look: ClipLook?
    @ObservationIgnored let lookBox = LookBox()
    #endif
    /// Subtitles made from the transcript and edited here, with their look and place.
    var subtitles: [SubtitleCue] = []
    var subtitleStyle = SubtitleStyle()
    /// Shown on the picture and burned into the export.
    var showSubtitles = true

    @ObservationIgnored private var observer: Any?
    @ObservationIgnored private var scrubbing = false

    static let thumbnailCount = 60
    /// A range to start with (screenshots).
    static var startRange: (Double, Double)?
    /// Where to start once loaded (opened at a moment: a search hit, a transcript line).
    var startAt: Double?
    nonisolated static let peakCount = 3000

    init(file: URL) {
        self.file = file
        player.actionAtItemEnd = .pause
    }

    var rangeStart: Double { inPoint ?? 0 }
    var rangeEnd: Double { outPoint ?? duration }
    var hasRange: Bool { inPoint != nil || outPoint != nil }
    var isPlaying: Bool { rate != 0 }
    var frame: Double { 1 / max(frameRate, 1) }

    // MARK: - Loading

    /// While a playable copy is being made, what's happening.
    private(set) var preparing: String?

    func load(ffmpeg: String?, ffprobe: String? = nil) async {
        guard !loaded else { return }
        loaded = true
        var asset = AVURLAsset(url: file)
        let readable = await read(asset)
        // macOS can't play some files (WebM, MKV), or misreads their length (Opus): then the
        // Editor plays a copy it can, made once and kept in Pluck's cache. Exports still use
        // the original file, with the same timing.
        if let ffprobe, let ffmpeg, let probe = await Self.probe(file, ffprobe: ffprobe),
           !readable || probe.duration > duration + 0.5 {
            preparing = probe.video ? String(localized: "Making a copy Pluck can play…") : String(localized: "Getting the sound ready…")
            if let copy = await Self.playableCopy(of: file, video: probe.video, ffmpeg: ffmpeg) {
                asset = AVURLAsset(url: copy)
                _ = await read(asset)
                problem = nil
            }
            preparing = nil
            if duration == 0 { duration = probe.duration }
        }
        guard duration > 0 else {
            problem = problem ?? String(localized: "Pluck can’t play this file.")
            return
        }
        player.replaceCurrentItem(with: AVPlayerItem(asset: asset))
        playedAsset = asset
        loadSubtitles()
        #if STUDIO
        loadLook()
        await applyLook()
        #endif
        if ScreenshotMode.scene == "editor", let list = UserDefaults.standard.string(forKey: "PluckScreenshotCuts") {
            // "10,25,40": cuts; a time after "x" is a part taken out ("10,25,x10").
            for item in list.split(separator: ",") {
                if item.hasPrefix("x"), let start = Double(item.dropFirst()) { removed.insert(start) }
                else if let time = Double(item) { cuts.append(time) }
            }
            cuts.sort()
        }
        if let startAt {
            self.startAt = nil
            seek(to: startAt)
        }
        if let (start, end) = Self.startRange {
            Self.startRange = nil
            inPoint = start
            outPoint = end
            seek(to: (start + end) / 2)
        }
        observer = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 60), queue: .main) { [weak self] time in
            MainActor.assumeIsolated { self?.tick(time.seconds) }
        }
        let playable = asset
        async let pictures: Void = loadThumbnails(playable)
        async let sound: Void = loadPeaks(ffmpeg: ffmpeg)
        _ = await (pictures, sound)
        await analyse(ffmpeg: ffmpeg, ffprobe: ffprobe)
    }

    /// The file's chapters, then its pauses, then the cuts between shots (the slowest), each shown
    /// as soon as it's found.
    private func analyse(ffmpeg: String?, ffprobe: String?) async {
        if let ffprobe {
            markers += await EditorAnalysis.chapters(in: file, ffprobe: ffprobe)
        }
        guard let ffmpeg else { return }
        analysing = String(localized: "Finding pauses…")
        markers += await EditorAnalysis.silences(in: file, ffmpeg: ffmpeg)
        if hasVideo {
            analysing = String(localized: "Finding cuts…")
            markers += await EditorAnalysis.cuts(in: file, ffmpeg: ffmpeg)
        }
        analysing = nil
    }

    func replaceMarkers(_ kind: EditorMarker.Kind, with new: [EditorMarker]) {
        markers.removeAll { $0.kind == kind }
        markers += new
        shownKinds.insert(kind)
    }

    var visibleMarkers: [EditorMarker] { markers.filter { shownKinds.contains($0.kind) } }

    /// Where things can snap to: shown markers' edges, the range's edges and the playhead.
    func snapPoints(excluding: Double? = nil) -> [Double] {
        var points: [Double] = [0, duration, time]
        for marker in visibleMarkers {
            points.append(marker.start)
            if let end = marker.end { points.append(end) }
        }
        if let inPoint { points.append(inPoint) }
        if let outPoint { points.append(outPoint) }
        points += cuts
        return points.filter { $0 != excluding }
    }

    /// A time moved to the nearest snap point within `tolerance` seconds, when snapping is on.
    func snapped(_ seconds: Double, tolerance: Double, excluding: Double? = nil) -> Double {
        guard snapping else { return snappedToFrame(seconds) }
        let nearest = snapPoints(excluding: excluding).min { abs($0 - seconds) < abs($1 - seconds) }
        if let nearest, abs(nearest - seconds) <= tolerance { return snappedToFrame(nearest) }
        return snappedToFrame(seconds)
    }

    /// Sets the range to a marker (a moment, a pause, a chapter) and goes there.
    func select(_ marker: EditorMarker) {
        let end = marker.end ?? markers.filter { $0.kind == marker.kind && $0.start > marker.start }.map(\.start).min() ?? duration
        inPoint = snappedToFrame(marker.start)
        outPoint = snappedToFrame(end)
        seek(to: marker.start)
    }

    // MARK: - Reading the file

    /// What macOS makes of the file: its length, and the picture's shape and frame rate.
    /// False when it can't play it.
    private func read(_ asset: AVURLAsset) async -> Bool {
        do {
            duration = try await asset.load(.duration).seconds
            hasVideo = false
            if let track = try await asset.loadTracks(withMediaType: .video).first {
                hasVideo = true
                let (size, transform, rate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
                let upright = CGRect(origin: .zero, size: size).applying(transform)
                aspect = abs(upright.width) / max(abs(upright.height), 1)
                pixelSize = CGSize(width: abs(upright.width), height: abs(upright.height))
                if rate > 0 { frameRate = Double(rate) }
            }
            let playable = try await asset.load(.isPlayable)
            return playable && duration > 0
        } catch {
            problem = error.localizedDescription
            return false
        }
    }

    /// The file's real length, and whether it has a picture (a song's cover isn't one), as
    /// ffprobe reads it.
    nonisolated static func probe(_ file: URL, ffprobe: String) async -> (duration: Double, video: Bool)? {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffprobe)
            process.arguments = ["-v", "error", "-show_entries", "format=duration:stream=codec_type:stream_disposition=attached_pic",
                                 "-of", "json", file.path]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return nil }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let duration = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init) else { return nil }
            let video = (json["streams"] as? [[String: Any]] ?? []).contains { stream in
                stream["codec_type"] as? String == "video" && ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int ?? 0) == 0
            }
            return (duration, video)
        }.value
    }

    /// A copy macOS plays, in Pluck's cache (made once per file and version): AAC sound, and
    /// H.264 up to 1080p for video, same timing. Copies not opened for two weeks go.
    nonisolated static func playableCopy(of file: URL, video: Bool, ffmpeg: String) async -> URL? {
        let folder = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0].appendingPathComponent("Pluck/Editor", isDirectory: true)
        let stamp = (try? file.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])).map {
            "\($0.fileSize ?? 0)-\(Int($0.contentModificationDate?.timeIntervalSince1970 ?? 0))"
        } ?? ""
        let name = SHA256.hash(data: Data((file.path + stamp).utf8)).prefix(10).map { String(format: "%02x", $0) }.joined() + (video ? ".mov" : ".m4a")
        let copy = folder.appendingPathComponent(name)
        let old = Date.now.addingTimeInterval(-14 * 86_400)
        for item in (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentAccessDateKey])) ?? [] where item != copy {
            if let used = try? item.resourceValues(forKeys: [.contentAccessDateKey]).contentAccessDate, used < old {
                try? FileManager.default.removeItem(at: item)
            }
        }
        if FileManager.default.fileExists(atPath: copy.path) { return copy }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let partial = folder.appendingPathComponent("partial-" + name)
        var arguments = ["-nostdin", "-y", "-v", "error", "-i", file.path]
        if video {
            arguments += ["-map", "0:v:0", "-map", "0:a:0?", "-vf", "scale=-2:'min(1080,ih)'", "-c:v", "h264_videotoolbox", "-b:v", "8M",
                          "-pix_fmt", "yuv420p", "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart"]
        } else {
            arguments += ["-vn", "-c:a", "aac", "-b:a", "192k"]
        }
        let made = await Task.detached { () -> Bool in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = arguments + [partial.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return false }
            process.waitUntilExit()
            return process.terminationStatus == 0
        }.value
        guard made, (try? FileManager.default.moveItem(at: partial, to: copy)) != nil else {
            try? FileManager.default.removeItem(at: partial)
            return nil
        }
        return copy
    }

    private func loadThumbnails(_ asset: AVURLAsset) async {
        guard hasVideo else { return }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 320, height: 320)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1, preferredTimescale: 600)
        let count = Self.thumbnailCount
        thumbnails = Array(repeating: nil, count: count)
        let times = (0..<count).map { CMTime(seconds: (Double($0) + 0.5) / Double(count) * duration, preferredTimescale: 600) }
        for await result in generator.images(for: times) {
            if let image = try? result.image, let slot = times.firstIndex(of: result.requestedTime) {
                thumbnails[slot] = image
            }
        }
    }

    /// The sound's peaks, read with ffmpeg at a low rate (plenty for drawing).
    private func loadPeaks(ffmpeg: String?) async {
        guard let ffmpeg else { return }
        let file = self.file, duration = self.duration
        let rate = duration > 1800 ? 500 : 2000
        let peaks = await Task.detached { () -> [Float] in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: ffmpeg)
            process.arguments = ["-nostdin", "-v", "error", "-i", file.path, "-vn", "-ac", "1", "-ar", String(rate), "-f", "f32le", "-"]
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return [] }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            guard !samples.isEmpty else { return [] }
            let buckets = min(Self.peakCount, samples.count)
            var peaks = [Float](repeating: 0, count: buckets)
            let per = Double(samples.count) / Double(buckets)
            for bucket in 0..<buckets {
                let start = Int(Double(bucket) * per), end = min(samples.count, max(start + 1, Int(Double(bucket + 1) * per)))
                var loudest: Float = 0
                for i in start..<end { loudest = max(loudest, abs(samples[i])) }
                peaks[bucket] = loudest
            }
            // Loud enough to see, also for quiet recordings.
            let top = max(peaks.max() ?? 1, 0.05)
            return peaks.map { min($0 / top, 1) }
        }.value
        self.peaks = peaks
    }

    /// The frame at the playhead as a full-size picture, saved where the person chooses.
    func saveFrame() {
        player.pause()
        let time = CMTime(seconds: self.time, preferredTimescale: 600)
        let file = self.file
        Task {
            let generator = AVAssetImageGenerator(asset: AVURLAsset(url: file))
            generator.appliesPreferredTrackTransform = true
            generator.requestedTimeToleranceBefore = .zero
            generator.requestedTimeToleranceAfter = .zero
            do {
                let image = try await generator.image(at: time).image
                guard let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else { return }
                let panel = NSSavePanel()
                panel.allowedContentTypes = [.png]
                panel.directoryURL = file.deletingLastPathComponent()
                let stamp = Format.duration(time.seconds).replacingOccurrences(of: ":", with: ".")
                panel.nameFieldStringValue = "\(file.deletingPathExtension().lastPathComponent) (\(stamp)).png"
                guard panel.runModal() == .OK, let url = panel.url else { return }
                try png.write(to: url, options: .atomic)
            } catch {
                NSAlert(error: error).runModal()
            }
        }
    }

    func close() {
        player.pause()
        if let observer { player.removeTimeObserver(observer) }
        observer = nil
    }

    // MARK: - Playing

    private func tick(_ seconds: Double) {
        guard !scrubbing, seconds.isFinite else { return }
        time = min(max(seconds, 0), duration)
        rate = player.rate
        // Parts taken out are skipped while playing, so the edit plays as it will be.
        if rate > 0, let part = part(at: time), part.removed {
            if part.end >= rangeEnd - frame / 2 {
                player.pause()
                rate = 0
                seek(to: min(part.end, rangeEnd))
            } else {
                seek(to: part.end)
                player.rate = rate
            }
            return
        }
        // Playing a range stops at its out point, or goes round again.
        if rate > 0, outPoint != nil || loop, time >= rangeEnd - frame / 2 {
            if loop {
                seek(to: rangeStart)
                player.rate = rate
            } else {
                player.pause()
                rate = 0
                seek(to: rangeEnd)
            }
        }
    }

    func togglePlay() {
        if isPlaying {
            player.pause()
        } else {
            // From the end, start again from the range's start.
            if time >= rangeEnd - frame { seek(to: rangeStart) }
            player.rate = 1
        }
        rate = player.rate
    }

    /// J, K and L: each L plays faster forward (1×, 2×, 4×, 8×), each J faster backward, K stops.
    func shuttle(_ direction: Int) {
        guard direction != 0 else { player.pause(); rate = 0; return }
        let current = player.rate
        let next: Float
        if direction > 0 {
            next = current > 0 ? min(current * 2, 8) : 1
        } else {
            next = current < 0 ? max(current * 2, -8) : -1
        }
        // Not every file can play backwards; then step back a second at a time instead.
        if next < 0, player.currentItem?.canPlayReverse != true {
            step(seconds: -1)
            return
        }
        player.rate = next
        rate = next
    }

    func seek(to seconds: Double, exact: Bool = true) {
        let target = min(max(seconds, 0), duration)
        time = target
        let tolerance = exact ? CMTime.zero : CMTime(seconds: 0.1, preferredTimescale: 600)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func step(frames: Int) {
        player.pause()
        rate = 0
        seek(to: (time / frame).rounded() * frame + Double(frames) * frame)
    }

    func step(seconds: Double) {
        seek(to: time + seconds)
    }

    /// While the playhead is dragged: quick, rough seeks, then an exact one when it's let go.
    func scrub(to seconds: Double) {
        scrubbing = true
        player.pause()
        rate = 0
        seek(to: seconds, exact: false)
    }

    func endScrub(at seconds: Double) {
        scrubbing = false
        seek(to: seconds)
    }

    // MARK: - In and out

    func markIn(at seconds: Double? = nil) {
        let point = snappedToFrame(seconds ?? time)
        inPoint = point
        if let outPoint, outPoint <= point { self.outPoint = nil }
    }

    func markOut(at seconds: Double? = nil) {
        let point = snappedToFrame(seconds ?? time)
        outPoint = point
        if let inPoint, inPoint >= point { self.inPoint = nil }
    }

    func clearRange() {
        inPoint = nil
        outPoint = nil
    }

    func snappedToFrame(_ seconds: Double) -> Double {
        min(max((seconds / frame).rounded() * frame, 0), duration)
    }

    /// The range as a clip to export, or nil for the whole file.
    var clip: ClipRange? {
        guard hasRange else { return nil }
        return ClipRange(start: rangeStart, end: outPoint)
    }

    // MARK: - Showing time

    /// "01:23:10" (minutes, seconds, frames) or with hours for long files.
    func timecode(_ seconds: Double) -> String {
        let fps = max(Int(frameRate.rounded()), 1)
        let totalFrames = Int((seconds * Double(fps)).rounded())
        let frames = totalFrames % fps, totalSeconds = totalFrames / fps
        let s = totalSeconds % 60, m = (totalSeconds / 60) % 60, h = totalSeconds / 3600
        return duration >= 3600 ? String(format: "%d:%02d:%02d:%02d", h, m, s, frames) : String(format: "%02d:%02d:%02d", m, s, frames)
    }
}
