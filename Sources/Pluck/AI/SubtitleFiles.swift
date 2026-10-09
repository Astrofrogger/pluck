import Foundation
import NaturalLanguage
import Translation

/// Subtitle files from this Mac (.srt and .vtt): read, translated with local AI, and written
/// next to the original as "Video.nl.srt".
enum SubtitleFiles {
    static let extensions: Set<String> = ["srt", "vtt"]

    static func isSubtitle(_ url: URL) -> Bool {
        extensions.contains(url.pathExtension.lowercased())
    }

    enum Failure: LocalizedError {
        case unreadable(String)
        case empty(String)

        var errorDescription: String? {
            switch self {
            case .unreadable(let name): String(localized: "Pluck couldn’t read “\(name)”.")
            case .empty(let name): String(localized: "“\(name)” has no subtitles in it.")
            }
        }
    }

    // MARK: - Reading

    static func cues(in url: URL) throws -> [Transcript.Cue] {
        guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .windowsCP1252)) else {
            throw Failure.unreadable(url.lastPathComponent)
        }
        let cues = parse(text)
        guard !cues.isEmpty else { throw Failure.empty(url.lastPathComponent) }
        return cues
    }

    /// SRT and WebVTT cues: a timing line ("00:01:02,345 --> 00:01:04,000", VTT settings after
    /// it are ignored) followed by text. Styling tags are dropped, lines joined into one.
    static func parse(_ text: String) -> [Transcript.Cue] {
        let normalized = text.replacingOccurrences(of: "\u{FEFF}", with: "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var cues: [Transcript.Cue] = []
        for block in normalized.components(separatedBy: "\n\n") {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
            guard let timing = lines.firstIndex(where: { $0.contains("-->") }) else { continue }
            let parts = lines[timing].components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = seconds(parts[0]),
                  let end = seconds(parts[1].split(separator: " ", omittingEmptySubsequences: true).first.map(String.init) ?? "") else { continue }
            let body = lines[(timing + 1)...].map(clean).filter { !$0.isEmpty }.joined(separator: " ")
            guard !body.isEmpty else { continue }
            cues.append(Transcript.Cue(start: start, end: end, text: body, words: 0..<0))
        }
        return cues
    }

    /// "01:02:03,456", "01:02:03.456" or "02:03.456".
    private static func seconds(_ stamp: String) -> Double? {
        let parts = stamp.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".").split(separator: ":")
        guard (2...3).contains(parts.count) else { return nil }
        var total = 0.0
        for part in parts {
            guard let value = Double(part) else { return nil }
            total = total * 60 + value
        }
        return total
    }

    /// Without <i>, <font …>, <c.yellow> or {\an8}.
    private static func clean(_ line: String) -> String {
        line.replacingOccurrences(of: "<[^>]*>|\\{\\\\[^}]*\\}", with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    // MARK: - Language

    /// The language the subtitles are in, as the system's language recognizer sees it.
    static func language(of cues: [Transcript.Cue]) -> Locale.Language? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(cues.prefix(200).map(\.text).joined(separator: " "))
        guard let language = recognizer.dominantLanguage, language != .undetermined else { return nil }
        return Locale.Language(identifier: language.rawValue)
    }

    // MARK: - Writing

    /// "Video.srt" or "Video.en.srt" becomes "Video.nl.srt" (same format as the original, never
    /// the original itself).
    static func translatedURL(for url: URL, to target: Locale.Language) -> URL {
        var base = url.deletingPathExtension()
        let suffix = base.pathExtension
        if (2...7).contains(suffix.count), suffix.allSatisfy({ $0.isLetter || $0 == "-" || $0 == "_" }),
           Locale.current.localizedString(forIdentifier: suffix) != nil {
            base = base.deletingPathExtension()
        }
        var output = base.appendingPathExtension(target.minimalIdentifier).appendingPathExtension(url.pathExtension.lowercased())
        if output.standardizedFileURL.path == url.standardizedFileURL.path {
            output = base.appendingPathExtension("\(target.minimalIdentifier)-translated").appendingPathExtension(url.pathExtension.lowercased())
        }
        return output
    }

    static func contents(_ cues: [Transcript.Cue], vtt: Bool) -> String {
        guard vtt else { return Transcript.srt(cues) }
        return "WEBVTT\n\n" + cues.map { cue in
            "\(Transcript.timestamp(cue.start)) --> \(Transcript.timestamp(cue.end))\n\(Transcript.twoLines(cue.text))\n"
        }.joined(separator: "\n")
    }

    /// Translates one file with local AI (Apple's on-device translation) and saves it next to
    /// the original. Returns the new file.
    @available(macOS 15, *)
    static func translate(_ url: URL, to target: Locale.Language, session: TranslationSession) async throws -> URL {
        var cues = try cues(in: url)
        let requests = cues.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset)) }
        for response in try await session.translations(from: requests) {
            guard let id = response.clientIdentifier, let index = Int(id), cues.indices.contains(index) else { continue }
            cues[index].text = response.targetText
        }
        let output = translatedURL(for: url, to: target)
        try contents(cues, vtt: url.pathExtension.lowercased() == "vtt").write(to: output, atomically: true, encoding: .utf8)
        return output
    }
}
