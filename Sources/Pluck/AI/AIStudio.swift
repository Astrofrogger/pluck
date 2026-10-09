import AppKit
import Foundation

/// Runs Pluck's local-AI jobs on finished downloads and converted files: transcripts and
/// subtitles, summaries and chapters, shorts and stems. Progress shows in the item's row.
@MainActor
@Observable
final class AIStudio {
    @ObservationIgnored private unowned let manager: DownloadManager

    init(manager: DownloadManager) {
        self.manager = manager
    }

    /// Files waiting for the user to choose subtitle options.
    var subtitleBatch: Batch?

    /// One or more items an AI action runs on with the same options (a selection in the list,
    /// or several files dropped at once).
    struct Batch: Identifiable {
        let id = UUID()
        let items: [DownloadItem]
        init(_ items: [DownloadItem]) { self.items = items }

        /// The item's title, or "3 files".
        @MainActor var title: String {
            items.count == 1 ? items[0].title : String(localized: "\(items.count) files")
        }
    }
    /// A video waiting for the user to choose shorts options.
    var shortsItem: DownloadItem?
    /// Summarize or Add Chapters waiting for the spoken language (files without a transcript).
    var languageAsk: LanguageAsk?

    struct LanguageAsk: Identifiable {
        enum Action { case summarize, chapters }
        let id = UUID()
        let item: DownloadItem
        let action: Action
        let openPlayer: (PlayerTarget) -> Void
    }

    /// Summarize or Add Chapters: straight away when there's a transcript, otherwise after asking
    /// which language is spoken (a guess from the title is often wrong for files from this Mac).
    func start(_ action: LanguageAsk.Action, _ item: DownloadItem, openPlayer: @escaping (PlayerTarget) -> Void) {
        let hasTranscript = item.transcriptID.flatMap(TranscriptStore.load)?.filePath == item.existingFile?.path
        guard !hasTranscript, LocalAI.canTranscribe else {
            switch action {
            case .summarize: summarize(item, openPlayer: openPlayer)
            case .chapters: addChapters(item, openPlayer: openPlayer)
            }
            return
        }
        languageAsk = LanguageAsk(item: item, action: action, openPlayer: openPlayer)
    }

    /// A file waiting for Remove Silences & Fillers options.
    var tightenBatch: Batch?
    /// A file waiting for Clean Up Audio options.
    var cleanupBatch: Batch?
    /// A video waiting for Upscale & Smooth options.
    var enhanceItem: DownloadItem?
    /// A video waiting for New Background options.
    var backgroundItem: DownloadItem?
    /// A video waiting for Privacy Blur options.
    var blurItem: DownloadItem?
    var searchShown = false
    @ObservationIgnored let search = TranscriptSearch()

    // MARK: - Transcripts in the background (for search)

    /// AI jobs run one at a time, in the order they were asked for, so a pile of them doesn't
    /// overload the Mac. Each item shows "Waiting…" until its turn.
    @ObservationIgnored private var jobs: [(item: DownloadItem, work: @MainActor () async -> Void)] = []
    @ObservationIgnored private var jobsRunning = false

    func enqueue(_ item: DownloadItem, waiting: String = String(localized: "Waiting…"), _ work: @escaping @MainActor () async -> Void) {
        item.aiStatus = waiting
        item.aiProgress = nil
        jobs.append((item, work))
        guard !jobsRunning else { return }
        jobsRunning = true
        Task {
            while !jobs.isEmpty {
                let job = jobs.removeFirst()
                await job.work()
            }
            jobsRunning = false
        }
    }

    /// A download finished: transcribe it if automatic transcripts are on.
    func downloadFinished(_ item: DownloadItem) {
        guard UserDefaults.standard.bool(forKey: Prefs.aiAutoTranscribe) else { return }
        transcribeInBackground([item])
    }

    /// Videos and songs among these that have no transcript yet.
    func needsTranscript(_ items: [DownloadItem]) -> [DownloadItem] {
        items.filter { item in
            guard item.transcriptID == nil, let file = item.existingFile, !file.hasDirectoryPath else { return false }
            return Converting.isMedia(file)
        }
    }

    /// Transcribes one file at a time, quietly, so search can find what was said in them.
    func transcribeInBackground(_ items: [DownloadItem]) {
        guard LocalAI.canTranscribe else { return }
        for item in needsTranscript(items) where item.aiStatus == nil {
            enqueue(item, waiting: String(localized: "Waiting to transcribe…")) {
                guard #available(macOS 26, *), let file = item.existingFile else { item.aiStatus = nil; return }
                do {
                    _ = try await self.existingOrNewTranscript(for: item, file: file)
                } catch {
                    // A file without speech just doesn't get a transcript; nothing to tell anyone.
                }
                item.aiStatus = nil
                item.aiProgress = nil
            }
        }
    }

    // MARK: - Transcripts and subtitles

    struct SubtitleRequest {
        var language: Locale
        /// Also make subtitles in these languages (translated on this Mac).
        var translateTo: [Locale.Language] = []
        /// The translation to burn into the picture; nil for the spoken language.
        var burnInLanguage: Locale.Language?
        /// Put "Name:" in front of lines where the speaker changes.
        var labelSpeakers = false
        var saveFile = true
        var embed = false
        var burnIn = false
        var design = CaptionDesign.load(CaptionDesign.subtitlesKey)
    }

    /// Whether this file can get subtitle tracks added (video containers ffmpeg can write them to).
    static func canEmbedSubtitles(_ file: URL) -> Bool {
        ["mp4", "m4v", "mov", "mkv", "webm"].contains(file.pathExtension.lowercased())
    }

    static func isVideo(_ file: URL) -> Bool { Converting.isVideo(file) }

    func makeSubtitles(for item: DownloadItem, _ request: SubtitleRequest) {
        guard #available(macOS 26, *), let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Preparing…")
            item.aiProgress = nil
            do {
                var transcript = try await transcript(for: item, file: file, language: request.language)
                if request.labelSpeakers, !transcript.hasSpeakers, Speakers.isSupported {
                    try await addSpeakers(to: &transcript, file: file, item: item)
                }
                let cues = transcript.cues()
                // Names go in after translating, so they're never translated themselves.
                let finish = { (cues: [Transcript.Cue]) in request.labelSpeakers ? transcript.labeled(cues) : cues }
                var tracks: [(cues: [Transcript.Cue], language: Locale.Language)] = [(cues, request.language.language)]
                let targets = request.translateTo.filter { $0.languageCode != request.language.language.languageCode }
                for (index, target) in targets.enumerated() {
                    item.aiStatus = targets.count > 1
                        ? String(localized: "Translating \(index + 1) of \(targets.count)…")
                        : String(localized: "Translating…")
                    item.aiProgress = targets.count > 1 ? Double(index) / Double(targets.count) : nil
                    tracks.append((try await OnDeviceTranslation.translate(cues, from: request.language, to: target), target))
                }
                let base = file.deletingPathExtension()
                if request.saveFile {
                    for (index, track) in tracks.enumerated() {
                        // "Video.srt" for the spoken language, "Video.nl.srt" for a translation.
                        let name = index == 0 ? base.lastPathComponent : "\(base.lastPathComponent).\(track.language.minimalIdentifier)"
                        let srt = base.deletingLastPathComponent().appendingPathComponent(name).appendingPathExtension("srt")
                        try Transcript.srt(finish(track.cues)).write(to: srt, atomically: true, encoding: .utf8)
                    }
                }
                if request.embed, Self.canEmbedSubtitles(file) {
                    item.aiStatus = String(localized: "Adding subtitles to the video…")
                    try await embed(tracks.map { (finish($0.cues), $0.language) }, into: file)
                }
                if request.burnIn, Self.isVideo(file),
                   let chosen = tracks.first(where: { $0.language.minimalIdentifier == request.burnInLanguage?.minimalIdentifier }) ?? tracks.first {
                    item.aiStatus = String(localized: "Burning in subtitles…")
                    item.aiProgress = 0
                    try await burnIn(finish(chosen.cues), design: request.design, into: file, item: item)
                }
                item.aiStatus = nil
                item.aiProgress = nil
                manager.saveHistory()
            } catch {
                item.aiStatus = nil
                item.aiProgress = nil
                presentError(error, for: item)
            }
        }
    }

    /// The saved transcript, or a new one: in `language` if the user chose it, otherwise in the
    /// guessed language (for jobs that just need one).
    @available(macOS 26, *)
    func existingOrNewTranscript(for item: DownloadItem, file: URL, language chosen: Locale? = nil) async throws -> Transcript {
        if let chosen { return try await transcript(for: item, file: file, language: chosen) }
        if let id = item.transcriptID, let saved = TranscriptStore.load(id), saved.filePath == file.path { return saved }
        let guess = LocalAI.guessLanguage(title: item.title, metadata: item.spokenLanguage)
        let supported = await OnDeviceSpeech.languages()
        let language = LocalAI.match(guess, in: supported) ?? Locale(identifier: "en-US")
        return try await transcript(for: item, file: file, language: language)
    }

    // MARK: - Summaries and chapters

    func summarize(_ item: DownloadItem, language: Locale? = nil, openPlayer: @escaping (PlayerTarget) -> Void) {
        guard #available(macOS 26, *), LocalAI.canSummarize, let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Preparing…")
            item.aiProgress = nil
            do {
                var transcript = try await existingOrNewTranscript(for: item, file: file, language: language)
                item.aiStatus = String(localized: "Summarizing…")
                item.aiProgress = 0
                let (summary, points) = try await OnDeviceWriter.summarize(transcript) { progress in
                    Task { @MainActor in item.aiProgress = progress }
                }
                transcript.summary = summary
                transcript.keyPoints = points
                TranscriptStore.save(transcript)
                finishJob(item)
                openPlayer(PlayerTarget(filePath: file.path, transcriptID: transcript.id, start: nil, tab: "summary"))
            } catch {
                failJob(item, error)
            }
        }
    }

    func addChapters(_ item: DownloadItem, language: Locale? = nil, openPlayer: @escaping (PlayerTarget) -> Void) {
        guard #available(macOS 26, *), LocalAI.canSummarize, let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Preparing…")
            item.aiProgress = nil
            do {
                var transcript = try await existingOrNewTranscript(for: item, file: file, language: language)
                item.aiStatus = String(localized: "Finding chapters…")
                item.aiProgress = 0
                let chapters = try await OnDeviceWriter.chapters(transcript) { progress in
                    Task { @MainActor in item.aiProgress = progress }
                }
                transcript.chapters = chapters
                TranscriptStore.save(transcript)
                if chapters.count > 1, ["mp4", "m4v", "mov", "m4a", "mkv"].contains(file.pathExtension.lowercased()) {
                    item.aiStatus = String(localized: "Adding chapters to the file…")
                    item.aiProgress = nil
                    try await write(chapters, into: file, duration: transcript.duration ?? item.duration)
                }
                finishJob(item)
                openPlayer(PlayerTarget(filePath: file.path, transcriptID: transcript.id, start: nil, tab: "chapters"))
            } catch {
                failJob(item, error)
            }
        }
    }

    /// Writes chapter markers into the file (streams copied), so QuickTime, Apple Music and
    /// other players show them.
    private func write(_ chapters: [Transcript.Chapter], into file: URL, duration: Double?) async throws {
        var meta = ";FFMETADATA1\n"
        for (index, chapter) in chapters.enumerated() {
            let end = index + 1 < chapters.count ? chapters[index + 1].start : (duration ?? chapter.start + 1)
            let title = chapter.title.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "=", with: "\\=")
                .replacingOccurrences(of: ";", with: "\\;").replacingOccurrences(of: "#", with: "\\#")
            meta += "[CHAPTER]\nTIMEBASE=1/1000\nSTART=\(Int(chapter.start * 1000))\nEND=\(Int(end * 1000))\ntitle=\(title)\n"
        }
        let metaFile = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-chapters-\(UUID().uuidString).txt")
        try meta.write(to: metaFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: metaFile) }
        let temp = file.deletingLastPathComponent().appendingPathComponent(".pluck-chapters-\(UUID().uuidString).\(file.pathExtension)")
        try await ffmpeg(["-y", "-v", "error", "-i", file.path, "-i", metaFile.path, "-map", "0", "-dn",
                          "-map_metadata", "0", "-map_chapters", "1", "-c", "copy", temp.path], failure: LocalAI.Failure.noAudio)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
    }

    func finishJob(_ item: DownloadItem) {
        item.aiStatus = nil
        item.aiProgress = nil
        manager.saveHistory()
    }

    func failJob(_ item: DownloadItem, _ error: Error) {
        item.aiStatus = nil
        item.aiProgress = nil
        presentError(error, for: item)
    }

    /// The file's transcript: the saved one if it's in the same language, otherwise a new one.
    @available(macOS 26, *)
    func transcript(for item: DownloadItem, file: URL, language: Locale) async throws -> Transcript {
        if let id = item.transcriptID, let saved = TranscriptStore.load(id),
           Locale(identifier: saved.language).language.languageCode == language.language.languageCode,
           saved.filePath == file.path {
            return saved
        }
        item.aiStatus = String(localized: "Reading sound…")
        let audio = try await extractAudio(from: file)
        defer { try? FileManager.default.removeItem(at: audio) }
        let words = try await OnDeviceSpeech.transcribe(audio, locale: language, duration: item.duration) { status, progress in
            Task { @MainActor in
                item.aiStatus = status
                item.aiProgress = progress
            }
        }
        let transcript = Transcript(id: item.transcriptID ?? UUID().uuidString, title: item.title, filePath: file.path,
                                    sourceURL: item.conversion == nil ? item.url : nil, language: language.identifier,
                                    duration: item.duration, created: .now, words: words)
        TranscriptStore.save(transcript)
        item.transcriptID = transcript.id
        manager.saveHistory()
        return transcript
    }

    /// 16 kHz mono WAV, what the speech recognizer works from.
    func extractAudio(from file: URL) async throws -> URL {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-\(UUID().uuidString).wav")
        try await ffmpeg(["-y", "-v", "error", "-i", file.path, "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", temp.path],
                         failure: LocalAI.Failure.noAudio)
        return temp
    }

    /// Adds subtitle tracks to the video file itself (streams copied, nothing re-encoded).
    private func embed(_ tracks: [(cues: [Transcript.Cue], language: Locale.Language)], into file: URL) async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-subs-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var inputs: [String] = ["-i", file.path]
        for (index, track) in tracks.enumerated() {
            let srt = folder.appendingPathComponent("\(index).srt")
            try Transcript.srt(track.cues).write(to: srt, atomically: true, encoding: .utf8)
            inputs += ["-i", srt.path]
        }
        let existing = await subtitleStreamCount(file)
        let codec = switch file.pathExtension.lowercased() {
        case "mkv": "srt"
        case "webm": "webvtt"
        default: "mov_text"
        }
        var args = ["-y", "-v", "error"] + inputs + ["-map", "0"]
        for index in tracks.indices { args += ["-map", "\(index + 1):0"] }
        args += ["-c", "copy", "-c:s", codec]
        for (index, track) in tracks.enumerated() {
            let code = track.language.languageCode?.identifier(.alpha3) ?? "und"
            args += ["-metadata:s:s:\(existing + index)", "language=\(code)"]
        }
        let temp = file.deletingLastPathComponent().appendingPathComponent(".pluck-subs-\(UUID().uuidString).\(file.pathExtension)")
        try await ffmpeg(args + [temp.path], failure: LocalAI.Failure.noAudio)
        _ = try FileManager.default.replaceItemAt(file, withItemAt: temp)
    }

    private func subtitleStreamCount(_ file: URL) async -> Int {
        guard let ffprobe = manager.tool("ffprobe") else { return 0 }
        return await Task.detached {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffprobe)
            p.arguments = ["-v", "error", "-select_streams", "s", "-show_entries", "stream=index", "-of", "csv=p=0", file.path]
            let pipe = Pipe()
            p.standardOutput = pipe
            p.standardError = FileHandle.nullDevice
            guard (try? p.run()) != nil else { return 0 }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return String(decoding: data, as: UTF8.self).split(separator: "\n").count
        }.value
    }

    /// A new copy of the video with the subtitles drawn into the picture.
    private func burnIn(_ cues: [Transcript.Cue], design: CaptionDesign, into file: URL, item: DownloadItem) async throws {
        let size = await videoSize(file) ?? (1920, 1080)
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-burn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let ass = folder.appendingPathComponent("subs.ass")
        try Captions.subtitles(cues, width: size.0, height: size.1, design: design).write(to: ass, atomically: true, encoding: .utf8)
        let output = Converting.outputURL(folder: file.deletingLastPathComponent().path,
                                          name: file.deletingPathExtension().lastPathComponent + String(localized: " (subtitled)"),
                                          fileExtension: "mp4")
        try await ffmpeg(["-y", "-v", "error", "-progress", "pipe:1", "-nostats", "-i", file.path,
                          "-vf", Captions.filter(ass),
                          "-c:v", "libx264", "-preset", "fast", "-crf", "18", "-pix_fmt", "yuv420p",
                          "-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", output.path],
                         failure: LocalAI.Failure.noAudio, duration: item.duration, item: item)
    }

    /// Pluck's (or the Mac's) copy of a helper tool like ffmpeg.
    func toolPath(_ name: String) -> String? { manager.tool(name) }

    /// A notification when Pluck is in the background (if the user turned them on).
    func notify(title: String, body: String, files: [URL]) {
        manager.notify(title: title, body: body, files: files)
    }

    func videoSize(_ file: URL) async -> (Int, Int)? {
        guard let ffprobe = manager.tool("ffprobe"),
              let info = await Converting.probe(file, ffprobe: ffprobe),
              let w = info.width, let h = info.height else { return nil }
        return (w, h)
    }

    // MARK: - Running ffmpeg

    struct ToolFailure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Runs ffmpeg; with `item`, its progress (from `-progress pipe:1`) shows in the row.
    func ffmpeg(_ args: [String], failure: Error, duration: Double? = nil, item: DownloadItem? = nil) async throws {
        guard let ffmpeg = manager.tool("ffmpeg") else { throw Converting.Failure.noFFmpeg }
        let env = manager.environment
        let (status, lastError) = await Task.detached { () -> (Int32, String?) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: ffmpeg)
            p.arguments = args
            p.environment = env
            let out = Pipe(), err = Pipe()
            p.standardOutput = out
            p.standardError = err
            guard (try? p.run()) != nil else { return (1, nil) }
            let errors = Task.detached { () -> String? in
                var last: String?
                for await line in PipeLines.stream(err.fileHandleForReading) where !line.isEmpty { last = line }
                return last
            }
            for await line in PipeLines.stream(out.fileHandleForReading) where line.hasPrefix("out_time_us=") {
                guard let item, let duration, duration > 0, let micro = Double(line.dropFirst("out_time_us=".count)) else { continue }
                let progress = min(max(micro / 1_000_000 / duration, 0), 1)
                await MainActor.run { item.aiProgress = progress }
            }
            p.waitUntilExit()
            return (p.terminationStatus, await errors.value)
        }.value
        guard status == 0 else { throw lastError.map { ToolFailure(message: $0) } ?? failure }
    }

    private func presentError(_ error: Error, for item: DownloadItem) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(item.title)” couldn’t be finished")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
