import Foundation

/// What was said in a video or song, word by word with timings, made on this Mac by the local
/// speech recognizer. Also holds what local AI later adds: a summary and chapters. Transcripts
/// are stored in Application Support/Pluck/Transcripts, one JSON file each, and are what
/// subtitles, search, summaries and shorts are built from.
struct Transcript: Codable, Identifiable, Sendable {
    struct Word: Codable, Sendable {
        /// Start and end in seconds.
        var s: Double
        var e: Double
        /// As recognised, usually with its leading space (" word").
        var t: String
    }

    struct Chapter: Codable, Sendable, Hashable {
        var start: Double
        var title: String
    }

    var id: String
    var title: String
    var filePath: String
    var sourceURL: String?
    /// BCP-47, e.g. "en-US".
    var language: String
    var duration: Double?
    var created: Date
    var words: [Word]
    var summary: String?
    var keyPoints: [String]?
    var chapters: [Chapter]?
    /// Who spoke when (local AI), if speakers were looked for.
    var speakerTurns: [SpeakerTurn]?
    /// Names the user gave the speakers, by number ("1": "Lowie").
    var speakerNames: [String: String]?

    struct SpeakerTurn: Codable, Sendable, Hashable {
        var s: Double
        var e: Double
        /// 1, 2, 3… in the order they first speak.
        var speaker: Int
    }

    var text: String { words.map(\.t).joined().trimmingCharacters(in: .whitespaces) }
    var fileURL: URL { URL(fileURLWithPath: filePath) }

    // MARK: - Subtitle cues

    struct Cue: Sendable, Identifiable, Hashable {
        var start: Double
        var end: Double
        var text: String
        /// The words this cue was made from (indices into `words`), for karaoke-style captions.
        var words: Range<Int>
        /// Who says it, when speakers are known.
        var speaker: Int? = nil
        var id: Double { start }
    }

    // MARK: - Speakers

    var hasSpeakers: Bool { !(speakerTurns ?? []).isEmpty }

    /// The speaker of each word: the turn it falls in, or the nearest one close by.
    func wordSpeakers() -> [Int?] {
        guard let turns = speakerTurns, !turns.isEmpty else { return Array(repeating: nil, count: words.count) }
        var result: [Int?] = []
        var last: Int?
        for word in words {
            let middle = (word.s + word.e) / 2
            let inside = turns.first { $0.s <= middle && middle <= $0.e }
            let near = inside ?? turns.min { distance($0, middle) < distance($1, middle) }.flatMap { distance($0, middle) < 1 ? $0 : nil }
            let speaker = near?.speaker ?? last
            result.append(speaker)
            last = speaker
        }
        return result
    }

    private func distance(_ turn: SpeakerTurn, _ time: Double) -> Double {
        time < turn.s ? turn.s - time : (time > turn.e ? time - turn.e : 0)
    }

    /// "Speaker 2", or the name the user gave them.
    func speakerName(_ speaker: Int) -> String {
        if let name = speakerNames?[String(speaker)], !name.trimmingCharacters(in: .whitespaces).isEmpty { return name }
        return String(localized: "Speaker \(speaker)")
    }

    /// The cue's text with "Name: " in front where the speaker changes (for subtitles and the
    /// language model, so it knows who said what).
    func labeled(_ cues: [Cue]) -> [Cue] {
        var previous: Int?
        return cues.map { cue in
            var cue = cue
            if let speaker = cue.speaker, speaker != previous {
                cue.text = "\(speakerName(speaker)): " + cue.text
            }
            previous = cue.speaker ?? previous
            return cue
        }
    }

    /// Words grouped into readable subtitles: at most `maxCharacters`, at most `maxDuration`
    /// seconds, split at pauses and after sentences where possible.
    func cues(maxCharacters: Int = 84, maxDuration: Double = 6) -> [Cue] {
        var cues: [Cue] = []
        var first = 0
        var text = ""
        let speakers = wordSpeakers()
        func close(at index: Int) {
            guard index > first else { return }
            let line = text.trimmingCharacters(in: .whitespaces)
            if !line.isEmpty {
                cues.append(Cue(start: words[first].s, end: words[index - 1].e, text: line, words: first..<index, speaker: speakers[first]))
            }
            first = index
            text = ""
        }
        for (index, word) in words.enumerated() {
            if index > first {
                let previous = words[index - 1]
                let tooLong = text.count + word.t.count > maxCharacters
                let tooSlow = word.e - words[first].s > maxDuration
                let pause = word.s - previous.e > 0.8
                let sentenceEnd = [".", "?", "!", "…"].contains { previous.t.hasSuffix($0) } && text.count > 20
                // A new speaker always starts a new line.
                let newSpeaker = speakers[index] != nil && speakers[index] != speakers[index - 1]
                if tooLong || tooSlow || pause || sentenceEnd || newSpeaker { close(at: index) }
            }
            text += word.t
        }
        close(at: words.count)
        return cues
    }

    /// Breaks a long cue into two balanced lines at the space nearest the middle.
    static func twoLines(_ text: String, longerThan limit: Int = 42) -> String {
        guard text.count > limit else { return text }
        let middle = text.index(text.startIndex, offsetBy: text.count / 2)
        let before = text[..<middle].lastIndex(of: " ")
        let after = text[middle...].firstIndex(of: " ")
        let split: String.Index? = switch (before, after) {
        case let (b?, a?): text.distance(from: b, to: middle) <= text.distance(from: middle, to: a) ? b : a
        case let (b?, nil): b
        case let (nil, a?): a
        default: nil
        }
        guard let split else { return text }
        return text[..<split] + "\n" + text[text.index(after: split)...]
    }

    // MARK: - Subtitle files

    static func srt(_ cues: [Cue]) -> String {
        cues.enumerated().map { index, cue in
            "\(index + 1)\n\(timestamp(cue.start, comma: true)) --> \(timestamp(cue.end, comma: true))\n\(twoLines(cue.text))\n"
        }.joined(separator: "\n")
    }

    /// "00:01:02,345" (SRT) or "00:01:02.345".
    static func timestamp(_ seconds: Double, comma: Bool = false) -> String {
        let ms = Int((max(seconds, 0) * 1000).rounded())
        return String(format: "%02d:%02d:%02d%@%03d", ms / 3_600_000, ms / 60_000 % 60, ms / 1000 % 60, comma ? "," : ".", ms % 1000)
    }

    /// ASS subtitles for burning into the picture. `karaoke` highlights each word as it's spoken
    /// (used for shorts); otherwise plain lower-third subtitles.
    static func ass(_ cues: [Cue], words: [Word], width: Int, height: Int, karaoke: Bool, offset: Double = 0) -> String {
        let size = karaoke ? Int(Double(height) * 0.045) : Int(Double(height) * 0.055)
        let margin = karaoke ? Int(Double(height) * 0.26) : Int(Double(height) * 0.06)
        // Colours are &HAABBGGRR. Karaoke: spoken words turn from white to Pluck pink.
        let primary = karaoke ? "&H006B5CFF" : "&H00FFFFFF"
        let secondary = "&H00FFFFFF"
        var out = """
        [Script Info]
        ScriptType: v4.00+
        PlayResX: \(width)
        PlayResY: \(height)
        WrapStyle: 0
        ScaledBorderAndShadow: yes

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, SecondaryColour, OutlineColour, BackColour, Bold, Italic, Underline, StrikeOut, ScaleX, ScaleY, Spacing, Angle, BorderStyle, Outline, Shadow, Alignment, MarginL, MarginR, MarginV, Encoding
        Style: Default,Helvetica Neue,\(size),\(primary),\(secondary),&H00000000,&H80000000,-1,0,0,0,100,100,0,0,1,\(max(size / 12, 2)),\(max(size / 20, 1)),2,\(width / 12),\(width / 12),\(margin),1

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text

        """
        func assTime(_ t: Double) -> String {
            let cs = Int((max(t, 0) * 100).rounded())
            return String(format: "%d:%02d:%02d.%02d", cs / 360_000, cs / 6000 % 60, cs / 100 % 60, cs % 100)
        }
        func escape(_ s: String) -> String {
            s.replacingOccurrences(of: "\\", with: "").replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        }
        for cue in cues {
            let start = cue.start - offset, end = cue.end - offset
            guard end > 0 else { continue }
            let text: String
            if karaoke {
                // {\kN} = this word lasts N centiseconds; the fill sweeps through each word in turn.
                var line = ""
                var cursor = cue.start
                for index in cue.words {
                    let word = words[index]
                    let lead = max(word.s - cursor, 0)
                    if lead > 0.01 { line += "{\\k\(Int((lead * 100).rounded()))}" }
                    line += "{\\k\(max(Int(((word.e - word.s) * 100).rounded()), 1))}" + escape(word.t).uppercased()
                    cursor = word.e
                }
                text = line.trimmingCharacters(in: .whitespaces)
            } else {
                text = escape(twoLines(cue.text)).replacingOccurrences(of: "\n", with: "\\N")
            }
            out += "Dialogue: 0,\(assTime(start)),\(assTime(end)),Default,,0,0,0,,\(text)\n"
        }
        return out
    }
}

/// Transcripts on disk.
enum TranscriptStore {
    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Transcripts", isDirectory: true)
    }

    static func url(for id: String) -> URL { folder.appendingPathComponent("\(id).json") }

    static func load(_ id: String) -> Transcript? {
        guard let data = try? Data(contentsOf: url(for: id)) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Transcript.self, from: data)
    }

    static func save(_ transcript: Transcript) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try? encoder.encode(transcript).write(to: url(for: transcript.id), options: .atomic)
        NotificationCenter.default.post(name: didSave, object: transcript.id)
    }

    /// Posted with the transcript's id after it's saved (a new summary, chapters…).
    static let didSave = Notification.Name("PluckTranscriptSaved")

    static func all() -> [Transcript] {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap { load($0.deletingPathExtension().lastPathComponent) }
    }

    /// The transcript of a file, if one was made.
    static func find(forFile path: String) -> Transcript? {
        all().first { $0.filePath == path }
    }
}

/// ffmpeg filter arguments.
enum FFmpegFilter {
    /// A path written so ffmpeg's filter syntax reads it literally.
    static func path(_ url: URL) -> String {
        url.path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'").replacingOccurrences(of: ",", with: "\\,")
    }
}
