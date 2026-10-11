import AppKit
import AVFoundation
import NaturalLanguage
import Vision

/// Delivery Check: a finished export, looked over before it goes out the way a finishing editor
/// would. Flash frames and black, a picture that stands still, sound that drops out or a silent
/// channel, loudness against where it's going, typos in on-screen text, text too close to the
/// edge, and the technical things platforms and broadcasters ask for. Everything runs on this
/// Mac (ffmpeg, and Apple's on-device text recognition and spelling).
enum DeliveryCheck {
    /// Where the video is going, which sets the loudness target, the picture shape and the safe areas.
    enum Destination: String, CaseIterable, Identifiable {
        case online, social, broadcastEU, broadcastUS, other
        var id: String { rawValue }

        var label: String {
            switch self {
            case .online: String(localized: "Online: YouTube, Vimeo, a website (16:9)")
            case .social: String(localized: "Social: Instagram, TikTok, Shorts (9:16)")
            case .broadcastEU: String(localized: "Broadcast, Europe: EBU R128")
            case .broadcastUS: String(localized: "Broadcast, US: ATSC A/85")
            case .other: String(localized: "Somewhere else (no targets)")
            }
        }

        /// Integrated loudness (LUFS), how far off is fine (LU), and the highest true peak (dBTP).
        var loudness: (target: Double, tolerance: Double, peak: Double)? {
            switch self {
            case .online, .social: (-14, 2, -1)
            case .broadcastEU: (-23, 0.5, -1)
            case .broadcastUS: (-24, 2, -2)
            case .other: nil
            }
        }

        /// Width ÷ height.
        var aspect: Double? {
            switch self {
            case .online, .broadcastEU, .broadcastUS: 16.0 / 9
            case .social: 9.0 / 16
            case .other: nil
            }
        }

        /// The area text should stay in (normalized, origin bottom left).
        var safeArea: CGRect {
            switch self {
            // Platform buttons and captions cover the top, the bottom and the right edge.
            case .social: CGRect(x: 0.06, y: 0.20, width: 0.80, height: 0.66)
            // Title safe: 90% of the picture.
            case .broadcastEU, .broadcastUS: CGRect(x: 0.05, y: 0.05, width: 0.90, height: 0.90)
            default: CGRect(x: 0.035, y: 0.035, width: 0.93, height: 0.93)
            }
        }
    }

    struct Issue: Identifiable {
        enum Severity: Int, Comparable {
            case problem, warning, note
            static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
        }

        let id = UUID()
        var severity: Severity
        /// Seconds into the video, if it's at a moment.
        var time: Double?
        var end: Double?
        var title: String
        var detail: String
        /// On-screen text: where it is (normalized, origin bottom left) and the word to learn.
        var box: CGRect?
        var word: String?
    }

    struct Report {
        var file: URL
        var destination: Destination
        var duration: Double
        var fps: Double
        /// The picture's size (for drawing on it).
        var size: CGSize
        /// The technical facts, for the top of the report.
        var facts: [(String, String)]
        var issues: [Issue]
    }

    /// Words someone told the check are spelled right (names, brands).
    static let knownWordsKey = "deliveryCheckKnownWords"

    static func learn(_ word: String) {
        var words = UserDefaults.standard.stringArray(forKey: knownWordsKey) ?? []
        if !words.contains(word.lowercased()) { words.append(word.lowercased()) }
        UserDefaults.standard.set(words, forKey: knownWordsKey)
    }

    // MARK: - Running

    static func run(_ file: URL, destination: Destination, ffmpeg: String, ffprobe: String,
                    progress: @escaping @Sendable (Double, String) -> Void) async throws -> Report {
        progress(0, String(localized: "Reading the file…"))
        guard let probe = await probe(file, ffprobe: ffprobe) else { throw Converting.Failure.noVideo }
        var issues = technical(probe, destination: destination)
        var facts = probe.facts
        try Task.checkCancellation()

        if probe.hasVideo {
            progress(0.05, String(localized: "Looking at every frame…"))
            issues += await picture(file, fps: probe.fps, duration: probe.duration, ffmpeg: ffmpeg) { value in
                progress(0.05 + value * 0.4, String(localized: "Looking at every frame…"))
            }
        }
        try Task.checkCancellation()

        if probe.channels > 0 {
            progress(0.45, String(localized: "Listening to the sound…"))
            let sound = await sound(file, channels: probe.channels, duration: probe.duration, destination: destination, ffmpeg: ffmpeg)
            issues += sound.issues
            facts += sound.facts
        }
        try Task.checkCancellation()

        if probe.hasVideo {
            issues += try await text(file, duration: probe.duration, destination: destination) { value in
                // Apple's text recognition loads the first time after a restart, which can take a minute.
                progress(0.55 + value * 0.45, value == 0 ? String(localized: "Reading the text on screen… The first time can take a minute.")
                                                         : String(localized: "Reading the text on screen…"))
            }
        }
        progress(1, "")
        issues.sort { ($0.severity, $0.time ?? -1) < ($1.severity, $1.time ?? -1) }
        return Report(file: file, destination: destination, duration: probe.duration, fps: probe.fps,
                      size: CGSize(width: max(probe.width, 1), height: max(probe.height, 1)), facts: facts, issues: issues)
    }

    // MARK: - The file itself

    private struct Probe {
        var duration = 0.0
        var hasVideo = false
        var width = 0, height = 0
        var fps = 25.0
        var variableRate = false
        var videoCodec = ""
        var channels = 0
        var sampleRate = 0
        var audioCodec = ""

        var facts: [(String, String)] {
            var result: [(String, String)] = []
            if hasVideo {
                result.append((String(localized: "Picture"), "\(width)×\(height), \(Self.rate(fps)) fps, \(videoCodec)"))
            }
            if channels > 0 {
                let layout = channels == 1 ? String(localized: "mono") : channels == 2 ? String(localized: "stereo") : String(localized: "\(channels) channels")
                result.append((String(localized: "Sound"), "\(layout), \(sampleRate / 1000) kHz, \(audioCodec)"))
            }
            result.append((String(localized: "Length"), DeliveryCheck.timecode(duration, fps: fps)))
            return result
        }

        static func rate(_ fps: Double) -> String {
            abs(fps - fps.rounded()) < 0.01 ? String(Int(fps.rounded())) : String(format: "%.3f", fps)
        }
    }

    private static func probe(_ file: URL, ffprobe: String) async -> Probe? {
        let output = await Self.output(ffprobe, ["-v", "error", "-show_entries",
            "format=duration:stream=codec_type,codec_name,width,height,avg_frame_rate,r_frame_rate,channels,sample_rate:stream_disposition=attached_pic",
            "-of", "json", file.path])
        guard let json = try? JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any] else { return nil }
        var probe = Probe()
        probe.duration = ((json["format"] as? [String: Any])?["duration"] as? String).flatMap(Double.init) ?? 0
        func rate(_ text: Any?) -> Double? {
            let parts = (text as? String)?.split(separator: "/").compactMap { Double($0) } ?? []
            return parts.count == 2 && parts[1] > 0 ? parts[0] / parts[1] : nil
        }
        for stream in json["streams"] as? [[String: Any]] ?? [] {
            let cover = ((stream["disposition"] as? [String: Any])?["attached_pic"] as? Int) == 1
            switch stream["codec_type"] as? String {
            case "video" where !cover && !probe.hasVideo:
                probe.hasVideo = true
                probe.width = stream["width"] as? Int ?? 0
                probe.height = stream["height"] as? Int ?? 0
                probe.videoCodec = stream["codec_name"] as? String ?? ""
                let average = rate(stream["avg_frame_rate"]), nominal = rate(stream["r_frame_rate"])
                probe.fps = average ?? nominal ?? 25
                if let average, let nominal, abs(average - nominal) > 0.05 { probe.variableRate = true }
            case "audio" where probe.channels == 0:
                probe.channels = stream["channels"] as? Int ?? 0
                probe.sampleRate = Int(stream["sample_rate"] as? String ?? "") ?? 0
                probe.audioCodec = stream["codec_name"] as? String ?? ""
            default:
                break
            }
        }
        return probe.duration > 0 ? probe : nil
    }

    private static func technical(_ probe: Probe, destination: Destination) -> [Issue] {
        var issues: [Issue] = []
        // As a plain string: numbers inside localized text get thousands separators (1.920).
        let size = "\(probe.width)×\(probe.height)"
        if probe.hasVideo, let aspect = destination.aspect, probe.height > 0 {
            let actual = Double(probe.width) / Double(probe.height)
            if abs(actual - aspect) > 0.02 {
                issues.append(Issue(severity: .problem, title: String(localized: "Wrong picture shape"),
                                    detail: String(localized: "It’s \(size); \(destination.label) expects \(aspect > 1 ? "16:9" : "9:16").")))
            }
            let long = max(probe.width, probe.height)
            if long < 1920 {
                issues.append(Issue(severity: .warning, title: String(localized: "Lower than HD"),
                                    detail: String(localized: "It’s \(size). Most places expect at least 1920 pixels along the long side.")))
            }
        }
        if probe.hasVideo, probe.width % 2 != 0 || probe.height % 2 != 0 {
            issues.append(Issue(severity: .problem, title: String(localized: "Odd picture size"),
                                detail: String(localized: "\(size) has an odd number of pixels; many players and platforms reject that.")))
        }
        if probe.variableRate {
            issues.append(Issue(severity: .warning, title: String(localized: "Variable frame rate"),
                                detail: String(localized: "The frame rate changes during the video, which can drift out of sync on some platforms. Export at a constant frame rate.")))
        }
        switch destination {
        case .broadcastEU where probe.hasVideo && ![25.0, 50.0].contains(where: { abs($0 - probe.fps) < 0.01 }):
            issues.append(Issue(severity: .problem, title: String(localized: "Frame rate"),
                                detail: String(localized: "European broadcast expects 25 or 50 fps; this is \(Probe.rate(probe.fps)).")))
        case .broadcastUS where probe.hasVideo && ![29.97, 59.94].contains(where: { abs($0 - probe.fps) < 0.01 }):
            issues.append(Issue(severity: .problem, title: String(localized: "Frame rate"),
                                detail: String(localized: "US broadcast expects 29.97 or 59.94 fps; this is \(Probe.rate(probe.fps)).")))
        default:
            break
        }
        if probe.channels == 0 {
            issues.append(Issue(severity: .warning, title: String(localized: "No sound"),
                                detail: String(localized: "The file has no sound track.")))
        } else if [.broadcastEU, .broadcastUS].contains(destination), probe.sampleRate != 48_000 {
            issues.append(Issue(severity: .problem, title: String(localized: "Sample rate"),
                                detail: String(localized: "Broadcast expects 48 kHz sound; this is \(probe.sampleRate / 1000) kHz.")))
        }
        return issues
    }

    // MARK: - The picture

    private static func picture(_ file: URL, fps: Double, duration: Double, ffmpeg: String,
                                progress: @escaping @Sendable (Double) -> Void) async -> [Issue] {
        let filter = "scale=320:-2,blackdetect=d=0:pix_th=0.1:pic_th=0.98,freezedetect=n=0.001:d=2,scdet=threshold=100,metadata=print:file=-"
        let output = await Self.output(ffmpeg, ["-nostdin", "-v", "error", "-i", file.path, "-an", "-vf", filter, "-f", "null", "-"]) { line in
            if line.hasPrefix("frame:"), let range = line.range(of: "pts_time:"), let t = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) {
                progress(min(t / max(duration, 1), 1))
            }
        }
        var times: [Double] = [], differences: [Double] = []
        var blacks: [(Double, Double?)] = [], freezes: [(Double, Double?)] = []
        var time = 0.0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("frame:") {
                if let range = line.range(of: "pts_time:") { time = Double(line[range.upperBound...].trimmingCharacters(in: .whitespaces)) ?? time }
                continue
            }
            let parts = line.split(separator: "=", maxSplits: 1)
            guard parts.count == 2, let value = Double(parts[1]) else { continue }
            switch parts[0] {
            case "lavfi.scd.mafd": times.append(time); differences.append(value)
            case "lavfi.black_start": blacks.append((value, nil))
            case "lavfi.black_end": if !blacks.isEmpty { blacks[blacks.count - 1].1 = value }
            case "lavfi.freezedetect.freeze_start": freezes.append((value, nil))
            case "lavfi.freezedetect.freeze_end": if !freezes.isEmpty { freezes[freezes.count - 1].1 = value }
            default: break
            }
        }
        let frame = 1 / max(fps, 1)
        var issues: [Issue] = []

        // Flash frames: one or two frames between two hard changes (a shot of a frame or two,
        // left behind on the timeline).
        func jump(_ i: Int) -> Bool {
            guard i >= 0, i < differences.count else { return false }
            let window = differences[max(0, i - 12)..<min(differences.count, i + 13)].sorted()
            return differences[i] >= max(8, window[window.count / 2] * 5)
        }
        var i = 1
        while i < differences.count - 1 {
            if jump(i) {
                if jump(i + 1) || jump(i + 2) {
                    let frames = jump(i + 1) ? 1 : 2
                    issues.append(Issue(severity: .problem, time: times[i], title: String(localized: "Flash frame"),
                                        detail: frames == 1 ? String(localized: "A single frame between two shots, probably left over from an edit.")
                                                            : String(localized: "Two frames between two shots, probably left over from an edit.")))
                    i += frames + 1
                    continue
                }
            }
            i += 1
        }

        // Black: a flash of black anywhere, or a stretch of it in the middle.
        for (start, endTime) in blacks {
            let end = endTime ?? duration
            let length = end - start
            let atEdge = start < frame * 1.5 || end > duration - frame * 1.5
            if length < frame * 3.5, !atEdge {
                issues.append(Issue(severity: .problem, time: start, end: end, title: String(localized: "Black flash"),
                                    detail: String(localized: "A frame or two of black in the middle of the video.")))
            } else if length >= 0.5, !atEdge {
                issues.append(Issue(severity: .warning, time: start, end: end, title: String(localized: "Black"),
                                    detail: String(localized: "\(String(format: "%.1f", length)) seconds of black. Fine if it’s meant as a pause.")))
            } else if atEdge, length > 2 {
                issues.append(Issue(severity: .note, time: start, end: end,
                                    title: start < 1 ? String(localized: "Black at the start") : String(localized: "Black at the end"),
                                    detail: String(localized: "\(String(format: "%.1f", length)) seconds of black. Some platforms pick a black first frame as the thumbnail.")))
            }
        }

        // A picture that stands still in the middle (an end card or a title is fine).
        for (start, endTime) in freezes {
            let end = endTime ?? duration
            guard end < duration - frame * 2, start > frame * 2 else { continue }
            issues.append(Issue(severity: .note, time: start, end: end, title: String(localized: "Picture stands still"),
                                detail: String(localized: "\(String(format: "%.1f", end - start)) seconds without any movement. Fine for a title or a still; check it isn’t a frozen render.")))
        }
        return issues
    }

    // MARK: - The sound

    private static func sound(_ file: URL, channels: Int, duration: Double, destination: Destination,
                              ffmpeg: String) async -> (issues: [Issue], facts: [(String, String)]) {
        let filter = "ebur128=peak=true,silencedetect=n=-60dB:d=1,astats=measure_perchannel=RMS_level+Peak_level:measure_overall=none"
        let output = await Self.output(ffmpeg, ["-nostdin", "-hide_banner", "-i", file.path, "-vn", "-af", filter, "-f", "null", "-"], stderr: true)
        func number(after label: String, in text: Substring) -> Double? {
            guard let range = text.range(of: label) else { return nil }
            let rest = text[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return Double(rest.prefix { "-+.0123456789".contains($0) })
        }
        var issues: [Issue] = [], facts: [(String, String)] = []
        let summary = output.range(of: "Summary:").map { output[$0.upperBound...] } ?? Substring("")
        let integrated = number(after: "I:", in: summary)
        let peak = number(after: "Peak:", in: summary)
        if let integrated {
            var text = String(format: "%.1f LUFS", integrated)
            if let peak { text += String(format: ", true peak %.1f dBTP", peak) }
            facts.append((String(localized: "Loudness"), text))
        }
        if let target = destination.loudness, let integrated {
            if integrated > target.target + target.tolerance {
                issues.append(Issue(severity: destination == .broadcastEU || destination == .broadcastUS ? .problem : .warning,
                                    title: String(localized: "Too loud"),
                                    detail: String(localized: "\(String(format: "%.1f", integrated)) LUFS; the target is \(String(format: "%.0f", target.target)). \(destination == .online || destination == .social ? String(localized: "Platforms turn it down, so it gains nothing.") : String(localized: "Broadcasters reject it."))")))
            } else if integrated < target.target - target.tolerance {
                issues.append(Issue(severity: destination == .broadcastEU || destination == .broadcastUS ? .problem : .warning,
                                    title: String(localized: "Too quiet"),
                                    detail: String(localized: "\(String(format: "%.1f", integrated)) LUFS; the target is \(String(format: "%.0f", target.target)). It will sound weaker than what plays before and after it.")))
            }
            if let peak, peak > target.peak {
                issues.append(Issue(severity: .problem, title: String(localized: "Peaks too high"),
                                    detail: String(localized: "The true peak is \(String(format: "%.1f", peak)) dBTP; keep it under \(String(format: "%.0f", target.peak)) or it can distort after the platform re-encodes it.")))
            }
        }

        // Dropouts: silence in the middle.
        var start: Double?
        for line in output.split(separator: "\n") {
            if let value = number(after: "silence_start:", in: line) { start = value }
            if let value = number(after: "silence_end:", in: line), let from = start {
                start = nil
                guard from > 0.5, value < duration - 0.5 else { continue }
                issues.append(Issue(severity: .warning, time: from, end: value, title: String(localized: "Sound drops out"),
                                    detail: String(localized: "\(String(format: "%.1f", value - from)) seconds of silence. Fine if it’s meant as a pause.")))
            }
        }

        // A channel without anything on it (a mono mix on one side only).
        var levels: [Double] = []
        for block in output.components(separatedBy: "Channel: ").dropFirst() {
            let text = Substring(block)
            if let rms = number(after: "RMS level dB:", in: text) { levels.append(rms) }
            else if text.contains("RMS level dB: -inf") { levels.append(-200) }
        }
        if levels.count >= 2, let loudest = levels.max(), loudest > -60 {
            for (index, level) in levels.enumerated() where level < -80 {
                let detail = levels.count != 2 ? String(localized: "Channel \(index + 1) has no sound at all.")
                    : index == 0 ? String(localized: "The left channel has no sound at all. On headphones it plays on one side only.")
                    : String(localized: "The right channel has no sound at all. On headphones it plays on one side only.")
                issues.append(Issue(severity: .problem, title: String(localized: "Silent channel"), detail: detail))
            }
        }
        return (issues, facts)
    }

    // MARK: - Text on screen

    private struct Seen {
        var text: String
        var box: CGRect
        var time: Double
    }

    private static func text(_ file: URL, duration: Double, destination: Destination,
                             progress: @escaping @Sendable (Double) -> Void) async throws -> [Issue] {
        let asset = AVURLAsset(url: file)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 1920, height: 1920)
        let tolerance = CMTime(seconds: 0.04, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance
        // Twice a second: titles and lower thirds stay up longer than that.
        let step = 0.5
        let times = stride(from: min(0.2, duration / 2), to: duration, by: step).map { $0 }
        var seen: [Seen] = []
        for (n, time) in times.enumerated() {
            try Task.checkCancellation()
            progress(Double(n) / Double(max(times.count, 1)))
            guard let image = try? await generator.image(at: CMTime(seconds: time, preferredTimescale: 600)).image else { continue }
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            // As written: correcting it would hide the very typos this is looking for.
            request.usesLanguageCorrection = false
            request.automaticallyDetectsLanguage = true
            try? VNImageRequestHandler(cgImage: image).perform([request])
            for observation in request.results ?? [] {
                guard let candidate = observation.topCandidates(1).first, candidate.confidence > 0.5 else { continue }
                let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
                guard text.count >= 3, observation.boundingBox.height > 0.015 else { continue }
                seen.append(Seen(text: text, box: observation.boundingBox, time: time))
            }
        }
        progress(1)

        var issues: [Issue] = []
        let known = Set(UserDefaults.standard.stringArray(forKey: knownWordsKey) ?? [])
        // Text that's really on screen stays there for more than one look (half a second apart);
        // animated text caught halfway ("Oblend…") and one-off misreadings don't.
        var looks: [String: Int] = [:]
        for item in seen { looks[item.text, default: 0] += 1 }
        let steady = seen.filter { (looks[$0.text] ?? 0) >= 2 }
        let languages = spellingLanguages(for: steady.map(\.text).joined(separator: " "))
        var reportedWords = Set<String>(), reportedEdges = Set<String>()
        let safe = destination.safeArea
        for item in steady {
            // Text near the edge, once per piece of text (big enough to be a title, not a
            // screen recording's small print).
            if !safe.contains(item.box), item.box.height > 0.025, !reportedEdges.contains(item.text) {
                reportedEdges.insert(item.text)
                issues.append(Issue(severity: .warning, time: item.time, title: String(localized: "Text close to the edge"),
                                    detail: String(localized: "“\(item.text)” is outside the safe area for \(destination.label); it can be cut off or covered."),
                                    box: item.box))
            }
            // Spelling, once per word. Web addresses and handles aren't words.
            guard !looksLikeAddress(item.text) else { continue }
            for (word, guess) in misspellings(in: item.text, languages: languages)
            where !known.contains(word.lowercased()) && !reportedWords.contains(word.lowercased()) {
                reportedWords.insert(word.lowercased())
                // A near miss of a real word is likely a typo; anything else is likely a name.
                let typo = guess.map { distance(word.lowercased(), $0.lowercased()) <= 2 } ?? false
                let detail = typo ? String(localized: "“\(word)” in “\(item.text)”. Did you mean “\(guess!)”?")
                                  : String(localized: "“\(word)” in “\(item.text)” isn’t in the dictionary. Fine if it’s a name.")
                issues.append(Issue(severity: typo ? .warning : .note, time: item.time, title: String(localized: "Check the spelling"),
                                    detail: detail, box: item.box, word: word))
            }
        }
        return issues
    }

    private static func looksLikeAddress(_ text: String) -> Bool {
        text.contains("/") || text.contains("@") || text.contains("www.")
            || text.range(of: #"[A-Za-z0-9-]+\.(com|be|nl|org|net|io|tv|me|co|app|de|fr|eu)\b"#, options: .regularExpression) != nil
    }

    /// The languages a word may be in: the text's own, English, and this Mac's.
    private static func spellingLanguages(for text: String) -> [String] {
        let available = NSSpellChecker.shared.availableLanguages
        func match(_ code: String) -> String? { available.first { $0 == code || $0.hasPrefix(code + "_") } }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        var codes = [recognizer.dominantLanguage?.rawValue, "en"]
        codes += Locale.preferredLanguages.map { String($0.prefix(2)) }
        var result: [String] = []
        for code in codes.compactMap({ $0 }) {
            if let language = match(code), !result.contains(language) { result.append(language) }
        }
        return result
    }

    /// Words no language in `languages` knows, with the first language's best guess.
    private static func misspellings(in text: String, languages: [String]) -> [(String, String?)] {
        let checker = NSSpellChecker.shared
        let ns = text as NSString
        var result: [(String, String?)] = []
        var start = 0
        while start < ns.length {
            let range = checker.checkSpelling(of: text, startingAt: start, language: languages.first, wrap: false,
                                              inSpellDocumentWithTag: 0, wordCount: nil)
            guard range.location != NSNotFound, range.length > 0 else { break }
            let word = ns.substring(with: range)
            start = range.location + range.length
            // Not words: numbers, codes, short abbreviations.
            guard word.count > 3, word.rangeOfCharacter(from: .decimalDigits) == nil else { continue }
            // Right in another of the languages: fine.
            let knownElsewhere = languages.dropFirst().contains { language in
                checker.checkSpelling(of: word, startingAt: 0, language: language, wrap: false,
                                      inSpellDocumentWithTag: 0, wordCount: nil).location == NSNotFound
            }
            guard !knownElsewhere else { continue }
            let guess = checker.guesses(forWordRange: range, in: text, language: languages.first, inSpellDocumentWithTag: 0)?.first
            // Only the capitals differ ("sabrina" for "Sabrina"): a style, not a typo.
            if let guess, guess.lowercased() == word.lowercased() { continue }
            result.append((word, guess))
        }
        return result
    }

    /// How many letters differ (insertions, deletions, changes).
    private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty, !b.isEmpty else { return max(a.count, b.count) }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + Array(repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }

    // MARK: - Helpers

    static func timecode(_ seconds: Double, fps: Double) -> String {
        let rate = max(Int(fps.rounded()), 1)
        let frames = Int((seconds * Double(rate)).rounded())
        return String(format: "%02d:%02d:%02d:%02d", frames / (rate * 3600), frames / (rate * 60) % 60, frames / rate % 60, frames % rate)
    }

    /// A tool's output (stdout, or stderr for ffmpeg's summaries), with each stdout line handed
    /// to `line` as it arrives.
    private static func output(_ tool: String, _ arguments: [String], stderr: Bool = false,
                               line: (@Sendable (Substring) -> Void)? = nil) async -> String {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: tool)
            process.arguments = arguments
            let pipe = Pipe()
            if stderr {
                process.standardError = pipe
                process.standardOutput = FileHandle.nullDevice
            } else {
                process.standardOutput = pipe
                process.standardError = FileHandle.nullDevice
            }
            guard (try? process.run()) != nil else { return "" }
            var data = Data()
            var pending = Data()
            while true {
                let chunk = pipe.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                data.append(chunk)
                if let line {
                    pending.append(chunk)
                    while let newline = pending.firstIndex(of: 0x0A) {
                        line(Substring(String(decoding: pending[pending.startIndex..<newline], as: UTF8.self)))
                        pending.removeSubrange(pending.startIndex...newline)
                    }
                }
            }
            process.waitUntilExit()
            return String(decoding: data, as: UTF8.self)
        }.value
    }
}
