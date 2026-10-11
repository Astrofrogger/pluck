import AVFoundation
import Foundation
import FoundationModels

/// Live Recorder: records a live stream to disk (or takes a file), and while it runs marks the
/// crowd cheering, music starting and stopping and silence, transcribes what's said, and picks
/// highlights, ready as a marked-up timeline in DaVinci Resolve.
@MainActor
@Observable
final class LiveSession {
    enum State: Equatable {
        case idle, recording, analysing, finished
        case failed(String)
    }

    private(set) var state: State = .idle
    private(set) var file: URL?
    private(set) var title = ""
    private(set) var events: [SoundTagger.Event] = []
    private(set) var words: [Transcript.Word] = []
    private(set) var highlights: [SoundTagger.Highlight] = []
    /// Seconds analysed, and transcribed.
    private(set) var analysed: Double = 0
    private(set) var transcribed: Double = 0
    private(set) var bytes: Int64 = 0
    private(set) var startedAt: Date?
    var transcriptionProblem: String?

    @ObservationIgnored private var tagger = SoundTagger()
    @ObservationIgnored private var recorder: Process?
    @ObservationIgnored private var loop: Task<Void, Never>?
    @ObservationIgnored private var language: Locale?
    @ObservationIgnored private var isLive = false
    @ObservationIgnored private var stopping = false
    @ObservationIgnored weak var manager: DownloadManager?

    var isRunning: Bool { state == .recording || state == .analysing }

    /// Sound is analysed in pieces this long, speech in pieces of 30 seconds.
    private static let piece = 15.0
    private static let speechPiece = 30.0

    // MARK: - Starting

    /// Records a live stream into the Downloads folder.
    func record(_ link: String, fromStart: Bool, language: Locale?) {
        guard let manager, let ytdlp = manager.tool("yt-dlp") else {
            state = .failed(String(localized: "Pluck couldn’t find yt-dlp."))
            return
        }
        reset(language: language)
        let folder = UserDefaults.standard.string(forKey: Prefs.downloadPath) ?? NSHomeDirectory() + "/Downloads"
        title = String(localized: "Live recording") + " " + Date.now.formatted(.dateTime.year().month(.twoDigits).day(.twoDigits).hour().minute())
        let output = Converting.outputURL(folder: folder, name: Folders.sanitize(title), fileExtension: "ts")
        file = output
        isLive = true
        // MPEG-TS, written as it comes in: playable and readable while the stream is still going.
        // ffmpeg follows an HLS live playlist until the stream really ends (yt-dlp's own
        // downloader stops at the end of the playlist as it is now, when a site doesn't say it's live).
        var args = ["--no-part", "--no-playlist", "--hls-use-mpegts", "--downloader", "m3u8:ffmpeg",
                    "-f", "b/best", "-o", output.path, "--newline"]
        if fromStart { args.append("--live-from-start") }
        args += manager.cookieArguments()
        args += ["--", link]
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ytdlp)
        process.arguments = args
        process.environment = manager.environment
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in
            let message = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            Task { @MainActor in self?.recorderEnded(status: finished.terminationStatus, log: message) }
        }
        do {
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        recorder = process
        startedAt = .now
        state = .recording
        startLoop()
    }

    /// Marks up a file from this Mac the same way, as fast as it can.
    /// Analyses a file and returns once it's done (for a batch).
    func analyseAndWait(_ url: URL, language: Locale?) async {
        analyse(url, language: language)
        await loop?.value
    }

    func analyse(_ url: URL, language: Locale?) {
        reset(language: language)
        file = url
        title = url.deletingPathExtension().lastPathComponent
        isLive = false
        state = .analysing
        startLoop()
    }

    func stop() {
        stopping = true
        // Interrupted, yt-dlp closes the recording cleanly.
        if let recorder, recorder.isRunning { recorder.interrupt() }
        else if !isLive { loop?.cancel() }
    }

    private func reset(language: Locale?) {
        tagger = SoundTagger()
        events = []; words = []; highlights = []
        analysed = 0; transcribed = 0; bytes = 0
        transcriptionProblem = nil
        stopping = false
        self.language = language
    }

    private func recorderEnded(status: Int32, log: String) {
        recorder = nil
        // Stopped by us, or the stream ended: either way analyse what's left.
        if !stopping, status != 0, (file.map { !FileManager.default.fileExists(atPath: $0.path) } ?? true) {
            let line = log.split(separator: "\n").last { $0.contains("ERROR") }.map(String.init) ?? log.suffix(300).description
            state = .failed(line.isEmpty ? String(localized: "The stream couldn’t be recorded.") : line)
            loop?.cancel()
            return
        }
        state = .analysing
    }

    // MARK: - Analysing as it comes in

    private func startLoop() {
        guard let file, let ffmpeg = manager?.tool("ffmpeg") else { return }
        loop?.cancel()
        loop = Task {
            while !Task.isCancelled {
                let recording = recorder?.isRunning ?? false
                bytes = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
                var progressed = false
                // Sound: a whole piece while recording; whatever is left once it has stopped.
                if bytes > 0, let samples = try? await AudioFeatures.samples(of: file, ffmpeg: ffmpeg, from: tagger.analysed, duration: Self.piece) {
                    let seconds = Double(samples.count) / AudioFeatures.sampleRate
                    if seconds >= Self.piece * 0.97 || (!recording && seconds > 0.5) {
                        tagger.add(AudioFeatures(samples: samples))
                        events = tagger.events
                        analysed = tagger.analysed
                        progressed = true
                    }
                }
                // Speech, when there's a whole piece to transcribe (or the rest at the end).
                // A piece once there are a few seconds past it to find a pause in (or the rest at the end).
                if let language, analysed - transcribed >= Self.speechPiece + 4 || (!recording && analysed > transcribed + 1) {
                    let finalPiece = !recording && analysed - transcribed <= Self.speechPiece + 4
                    await transcribe(file, from: transcribed, length: finalPiece ? analysed - transcribed : pieceLength(),
                                     language: language, ffmpeg: ffmpeg)
                    progressed = true
                }
                if !recording, !progressed, (isLive ? recorder == nil : true) {
                    break
                }
                if recording, !progressed { try? await Task.sleep(for: .seconds(3)) }
                if stopping, !isLive { break }
            }
            tagger.finish()
            events = tagger.events
            highlights = tagger.highlights()
            // What's said can be a highlight too: the local AI picks the most quotable lines.
            let quotes = await QuotePicker.pick(lines)
            for quote in quotes where !highlights.contains(where: { quote.start < $0.end && quote.end > $0.start }) {
                highlights.append(quote)
            }
            highlights.sort { $0.start < $1.start }
            saveSidecar()
            if case .failed = state {} else { state = .finished }
        }
    }

    /// A speech piece ends in the longest pause around its 30 seconds (from six seconds before to
    /// four after, as far as the sound is analysed), so it doesn't cut a sentence in two.
    private func pieceLength() -> Double {
        let loudness = tagger.loudness
        let bin = SoundTagger.bin
        let target = transcribed + Self.speechPiece
        let from = max(Int(((target - 6) / bin).rounded()), 0)
        let to = min(Int(((target + 4) / bin).rounded()), loudness.count)
        guard from < to else { return Self.speechPiece }
        let window = loudness[from..<to]
        // A pause: well under the typical level here (gaps between words don't get that quiet).
        let typical = window.sorted()[window.count / 2]
        let threshold = min(typical - 15, (window.min() ?? typical) + 6)
        var best = (start: from, length: 0), runStart: Int?
        for index in from...to {
            let quiet = index < to && loudness[index] <= threshold
            if quiet, runStart == nil { runStart = index }
            if !quiet, let start = runStart {
                if index - start > best.length { best = (start, index - start) }
                runStart = nil
            }
        }
        guard best.length > 0 else { return Self.speechPiece }
        let cut = Double(best.start) * bin + Double(best.length) * bin / 2
        return max(cut - transcribed, 5)
    }

    /// Each piece starts a little before the last one ended, so speech across the cut has context;
    /// words there are taken from the new piece.
    private static let overlap = 3.0

    private func transcribe(_ file: URL, from end: Double, length: Double, language: Locale, ffmpeg: String) async {
        guard #available(macOS 26, *), LocalAI.canTranscribe else {
            transcribed = analysed
            return
        }
        let start = max(0, end - Self.overlap)
        let fullLength = length + (end - start)
        let audio = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-live-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: audio) }
        _ = await ToolOutput.run(ffmpeg, ["-nostdin", "-y", "-v", "error", "-ss", String(start), "-t", String(fullLength), "-i", file.path,
                                          "-vn", "-ac", "1", "-ar", "16000", "-c:a", "pcm_s16le", audio.path])
        do {
            let piece = try await OnDeviceSpeech.transcribe(audio, locale: language, duration: fullLength) { _, _ in }
            // Words in the overlap come from this piece (the last one heard them without what follows),
            // except one cut off right at its start.
            let keepFrom = start + 0.5
            let fresh = piece.map { Transcript.Word(s: $0.s + start, e: $0.e + start, t: $0.t) }.filter { $0.s >= keepFrom || start == 0 }
            // A word both pieces heard (same word, about the same time) is taken from the new one,
            // which also heard what follows; everything the old piece had from there on goes.
            func bare(_ text: String) -> String { text.lowercased().trimmingCharacters(in: .whitespaces.union(.punctuationCharacters)) }
            let repeated = words.filter { old in fresh.contains { abs($0.s - old.s) < 0.6 && bare($0.t) == bare(old.t) } }.map(\.s).min()
            if let first = fresh.first {
                let cut = min(first.s, repeated ?? first.s) - 0.05
                words.removeAll { $0.s >= cut }
            }
            words += fresh
        } catch LocalAI.Failure.noSpeech {
            // A piece with only music or silence: nothing to add.
        } catch {
            transcriptionProblem = error.localizedDescription
        }
        transcribed = end + length
    }

    // MARK: - Results

    /// Moments where these words are said.
    func find(_ text: String) -> [(time: Double, line: String)] {
        let query = text.lowercased().trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty, !words.isEmpty else { return [] }
        let joined = words.map { $0.t.lowercased() }
        var results: [(Double, String)] = []
        var index = 0
        while index < words.count {
            // The phrase starting at this word, as long as the query.
            var phrase = ""
            var end = index
            while end < words.count, phrase.count < query.count + 20 {
                phrase += joined[end]
                end += 1
            }
            if phrase.trimmingCharacters(in: .whitespaces).hasPrefix(query) || (query.count > 3 && joined[index].contains(query)) {
                let context = words[max(0, index - 6)..<min(words.count, index + 14)].map(\.t).joined().trimmingCharacters(in: .whitespaces)
                results.append((words[index].s, context))
                index = end
            } else {
                index += 1
            }
        }
        return results
    }

    /// The transcript as subtitle lines, for reading along.
    var lines: [(time: Double, text: String)] { Self.lines(from: words) }

    static func lines(from words: [Transcript.Word]) -> [(time: Double, text: String)] {
        var result: [(Double, String)] = []
        var current = "", start = 0.0, last = 0.0
        for word in words {
            if current.isEmpty { start = word.s }
            // New line at a pause, after a sentence once the line has some length, or when long.
            let sentence = [".", "?", "!"].contains { current.trimmingCharacters(in: .whitespaces).hasSuffix($0) }
            if !current.isEmpty, word.s - last > 1.2 || (sentence && current.count > 50) || current.count > 180 {
                result.append((start, current.trimmingCharacters(in: .whitespaces)))
                current = ""
                start = word.s
            }
            current += word.t
            last = word.e
        }
        if !current.isEmpty { result.append((start, current.trimmingCharacters(in: .whitespaces))) }
        return result
    }

    /// What was found in a recording or a clip, as saved.
    struct Sidecar: Codable {
        var events: [SoundTagger.Event]
        var highlights: [SoundTagger.Highlight]
        var words: [Transcript.Word]
    }

    /// Where footage's results are kept: in Pluck's data, not next to it (footage is often on a
    /// client's drive or a camera card).
    static func sidecarURL(forFootage file: URL) -> URL {
        let folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Derush", isDirectory: true)
        // A hash of the path that stays the same between launches (unlike hashValue).
        var hash: UInt64 = 1469598103934665603
        for byte in file.path.utf8 { hash = (hash ^ UInt64(byte)) &* 1099511628211 }
        return folder.appendingPathComponent(file.deletingPathExtension().lastPathComponent + "-" + String(hash, radix: 16) + ".json")
    }

    /// The results saved for a clip by an earlier derush, if there are any.
    static func saved(forFootage file: URL) -> Sidecar? {
        guard let data = try? Data(contentsOf: sidecarURL(forFootage: file)) else { return nil }
        return try? JSONDecoder().decode(Sidecar.self, from: data)
    }

    /// Markers, highlights and transcript, as JSON (for later and for other tools): next to a
    /// live recording (Pluck's own file), in Pluck's data for footage.
    private func saveSidecar() {
        guard let file else { return }
        let sidecar = isLive ? file.deletingPathExtension().appendingPathExtension("pluck-markers.json") : Self.sidecarURL(forFootage: file)
        try? FileManager.default.createDirectory(at: sidecar.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? encoder.encode(Sidecar(events: events, highlights: highlights, words: words)).write(to: sidecar, options: .atomic)
    }

    /// The recording as a Resolve timeline with every marker, and a second timeline of the highlights.
    func buildInResolve() async throws -> String {
        guard let file else { throw ResolveBridge.Failure(message: String(localized: "Nothing recorded yet.")) }
        return try await MarkedTimeline.build(name: title, bin: String(localized: "Live recordings"),
                                              clips: [MarkedTimeline.Clip(file: file, length: analysed, events: events,
                                                                          highlights: highlights, lines: lines)])
    }
}

/// Recordings and footage in Resolve with their markers: the clips back to back with every
/// marker, and a second timeline of all highlights ("selects").
enum MarkedTimeline {
    struct Clip {
        var file: URL
        var length: Double
        var events: [SoundTagger.Event]
        var highlights: [SoundTagger.Highlight]
        var lines: [(time: Double, text: String)]
        /// What each shot shows, as a marker (searchable in Resolve's marker index).
        var shots: [(time: Double, text: String)] = []
    }

    /// A piece of a clip on a timeline of cuts, with markers at times within the clip.
    struct Cut {
        var file: URL
        var start: Double
        var end: Double
        /// Resolve's clip colour (Green, Orange…), or none.
        var colour: String?
        var markers: [(time: Double, colour: String, name: String, note: String)] = []
    }

    /// A timeline of cuts: the pieces back to back, with a marker naming each section where it
    /// starts. Returns the timeline's name in Resolve.
    @discardableResult
    static func buildCuts(name: String, bin: String, cuts: [Cut], sections: [(cut: Int, title: String)] = []) async throws -> String {
        guard !cuts.isEmpty else { return name }
        let files = Array(Set(cuts.map(\.file)))
        _ = try await ResolveBridge.run(["action": "import", "paths": files.map(\.path), "bin": bin])
        var rates: [URL: Double] = [:]
        for file in files {
            let track = try? await AVURLAsset(url: file).loadTracks(withMediaType: .video).first
            let rate = Double((try? await track?.load(.nominalFrameRate)) ?? 0)
            rates[file] = rate > 0 ? rate : 25
        }
        let (rate, name) = try await ResolveBridge.createTimeline(name, frameRate: rates[cuts[0].file] ?? 25)
        var items: [[String: Any]] = [], markers: [[String: Any]] = []
        var record = 0, starts: [Int] = []
        for cut in cuts {
            starts.append(record)
            let clipRate = rates[cut.file] ?? 25
            // Whole timeline frames first, the source length from those: rounding both on their own
            // (50 fps footage on a 25 fps timeline) leaves one-frame gaps and overlaps.
            let frames = Int(((cut.end - cut.start) * rate).rounded())
            let sourceIn = Int((cut.start * clipRate).rounded())
            let sourceOut = sourceIn + Int((Double(frames) * clipRate / rate).rounded())
            guard frames > 0, sourceOut > sourceIn else { continue }
            for mediaType in [1, 2] {
                var item: [String: Any] = ["path": cut.file.path, "track": 1, "recordIn": record, "sourceIn": sourceIn,
                                           "sourceOut": sourceOut, "mediaType": mediaType]
                if let colour = cut.colour { item["clipColor"] = colour }
                items.append(item)
            }
            for marker in cut.markers where marker.time >= cut.start && marker.time < cut.end {
                markers.append(["frame": record + Int(((marker.time - cut.start) * rate).rounded()), "color": marker.colour,
                                "name": String(marker.name.prefix(40)), "note": marker.note])
            }
            record += frames
        }
        for section in sections where section.cut < starts.count {
            markers.append(["frame": starts[section.cut], "color": "Blue", "name": String(section.title.prefix(40)), "note": section.title])
        }
        _ = try await ResolveBridge.run(["action": "buildTimeline", "name": name, "videoTracks": 1, "items": items, "markers": markers])
        return name
    }

    /// Builds the timelines; returns the name the main one has in Resolve.
    @discardableResult
    static func build(name: String, bin: String, clips: [Clip]) async throws -> String {
        guard !clips.isEmpty else { return name }
        _ = try await ResolveBridge.run(["action": "import", "paths": clips.map(\.file.path), "bin": bin])
        var rates: [URL: Double] = [:]
        for clip in clips {
            let track = try? await AVURLAsset(url: clip.file).loadTracks(withMediaType: .video).first
            let rate = Double((try? await track?.load(.nominalFrameRate)) ?? 0)
            rates[clip.file] = rate > 0 ? rate : 25
        }
        let (rate, name) = try await ResolveBridge.createTimeline(name, frameRate: rates[clips[0].file] ?? 25)
        var items: [[String: Any]] = [], markers: [[String: Any]] = []
        var record = 0
        for clip in clips {
            let clipRate = rates[clip.file] ?? 25
            let frames = Int((clip.length * clipRate).rounded())
            for mediaType in [1, 2] {
                items.append(["path": clip.file.path, "track": 1, "recordIn": record, "sourceIn": 0, "sourceOut": frames, "mediaType": mediaType])
            }
            func at(_ time: Double) -> Int { record + Int((time * rate).rounded()) }
            markers += clip.events.map { event in
                ["frame": at(event.time), "color": event.kind.colour, "name": event.kind.label,
                 "duration": max(1, Int((max(event.duration, 0.04) * rate).rounded())),
                 "note": event.kind == .cheer ? String(format: "+%.0f dB", event.strength) : ""]
            }
            markers += clip.highlights.map { ["frame": at($0.start), "color": "Red", "name": String(localized: "Highlight"),
                                              "duration": Int((($0.end - $0.start) * rate).rounded()), "note": $0.reason] }
            markers += clip.lines.map { ["frame": at($0.time), "color": "Sky", "name": String($0.text.prefix(40)), "note": $0.text] }
            markers += clip.shots.map { ["frame": at($0.time), "color": "Cream", "name": String($0.text.prefix(40)), "note": $0.text] }
            record += Int((clip.length * rate).rounded())
        }
        _ = try await ResolveBridge.run(["action": "buildTimeline", "name": name, "videoTracks": 1, "items": items, "markers": markers])

        let highlights = clips.flatMap { clip in clip.highlights.map { (clip.file, $0) } }
        guard !highlights.isEmpty else { return name }
        let (selectsRate, selectsName) = try await ResolveBridge.createTimeline(name + " – " + String(localized: "selects"),
                                                                                frameRate: rates[clips[0].file] ?? 25)
        var pieces: [[String: Any]] = [], notes: [[String: Any]] = []
        record = 0
        for (file, highlight) in highlights {
            let clipRate = rates[file] ?? 25
            let sourceIn = Int((highlight.start * clipRate).rounded()), sourceOut = Int((highlight.end * clipRate).rounded())
            for mediaType in [1, 2] {
                pieces.append(["path": file.path, "track": 1, "recordIn": record, "sourceIn": sourceIn, "sourceOut": sourceOut, "mediaType": mediaType])
            }
            notes.append(["frame": record, "color": "Red", "name": highlight.reason,
                          "note": file.lastPathComponent + " " + Duration.seconds(highlight.start).formatted(.time(pattern: .hourMinuteSecond))])
            record += Int(((highlight.end - highlight.start) * selectsRate).rounded())
        }
        _ = try await ResolveBridge.run(["action": "buildTimeline", "name": selectsName, "videoTracks": 1, "items": pieces, "markers": notes])
        return name
    }
}

/// The lines of a transcript most worth using in an edit, picked by the local AI.
enum QuotePicker {
    static func pick(_ lines: [(time: Double, text: String)], count: Int = 5) async -> [SoundTagger.Highlight] {
        guard #available(macOS 26, *), LocalAI.canSummarize, lines.count >= 3 else { return [] }
        let usable = Array(lines.prefix(400))
        let numbered = usable.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: """
            You help a video editor find soundbites. From the numbered transcript lines, pick up to \(count) lines that \
            would work best in an edit on their own: complete thoughts, strong or emotional statements, clear \
            introductions or conclusions. Reply with the line numbers only, comma-separated, best first.
            """)
        guard let reply = try? await session.respond(to: numbered).content else { return [] }
        let numbers = reply.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }.filter { (1...usable.count).contains($0) }
        var seen = Set<Int>()
        return numbers.filter { seen.insert($0).inserted }.prefix(count).map { number in
            let index = number - 1
            let start = max(0, usable[index].time - 0.4)
            let end = index + 1 < usable.count ? usable[index + 1].time : usable[index].time + 8
            return SoundTagger.Highlight(start: start, end: max(end, start + 2), reason: "“" + String(usable[index].text.prefix(80)) + "”", score: 1)
        }
    }
}
