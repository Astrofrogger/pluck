import Foundation
import FoundationModels

/// Summaries, key points and chapters from a transcript, written by Apple's on-device language
/// model (local AI, Apple Intelligence). Its context is small, so long transcripts are handled in
/// parts: each part is condensed, then the parts are combined.
@available(macOS 26, *)
enum OnDeviceWriter {
    @Generable
    struct Overview {
        @Guide(description: "A summary of the whole video in 3 to 5 sentences.")
        var summary: String
        @Guide(description: "The most important points, each one short sentence.", .count(3...6))
        var keyPoints: [String]
    }

    @Generable
    struct ChapterPlan {
        @Guide(description: "The topics of this part, in order.", .count(1...8))
        var chapters: [ChapterIdea]
    }

    @Generable
    struct ChapterIdea {
        @Guide(description: "The timestamp of the line where this topic starts, exactly as written in the transcript, like 03:15.")
        var start: String
        @Guide(description: "A short chapter title of at most 6 words.")
        var title: String
    }

    /// Roughly 1,000 words per request leaves room for instructions and the answer.
    private static let wordsPerPart = 1000

    /// The user's language, named in English for the model's instructions ("Dutch").
    private static var userLanguage: String {
        Locale(identifier: "en").localizedString(forLanguageCode: Locale.current.language.languageCode?.identifier ?? "en") ?? "English"
    }

    static func summarize(_ transcript: Transcript, progress: @escaping @Sendable (Double) -> Void) async throws -> (String, [String]) {
        let parts = chunks(of: transcript.cues().map(\.text), size: wordsPerPart)
        var notes: [String] = []
        if parts.count > 1 {
            for (index, part) in parts.enumerated() {
                let session = LanguageModelSession(instructions: """
                    You condense part of a video transcript into short factual notes. \
                    Keep names, numbers and conclusions. Write in \(userLanguage).
                    """)
                let reply = try await session.respond(to: "Transcript part \(index + 1) of \(parts.count):\n\(part)")
                notes.append(reply.content)
                progress(Double(index + 1) / Double(parts.count + 1))
            }
        }
        let material = parts.count > 1 ? notes.joined(separator: "\n\n") : parts.first ?? ""
        let session = LanguageModelSession(instructions: """
            You summarize videos for someone deciding whether to watch them. Be specific and \
            neutral; don't invent anything that isn't in the material. Write in \(userLanguage).
            """)
        let title = transcript.title
        let overview = try await session.respond(
            to: "Video title: \(title)\n\(parts.count > 1 ? "Notes on the video" : "Transcript"):\n\(material)",
            generating: Overview.self)
        progress(1)
        return (overview.content.summary, overview.content.keyPoints)
    }

    /// Chapters with real start times: the model only picks among the transcript's own
    /// timestamps, which are then matched back to the exact second.
    static func chapters(_ transcript: Transcript, progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.Chapter] {
        let cues = transcript.cues(maxCharacters: 160, maxDuration: 15)
        guard !cues.isEmpty else { return [] }
        let lines = cues.map { "[\(clock($0.start))] \($0.text)" }
        // Smaller parts than for summaries: the model then looks at every topic change closely.
        let parts = chunks(of: lines, size: 400)
        var found: [Transcript.Chapter] = []
        for (index, part) in parts.enumerated() {
            let session = LanguageModelSession(instructions: """
                You split a timestamped video transcript into chapters, like the chapters on a \
                YouTube video. Start a new chapter wherever the subject changes; a chapter usually \
                covers one to three minutes, so a part like this has two to four. Use the \
                timestamp of the line where each subject starts. Write the titles in the \
                language of the transcript.
                """)
            let plan = try await session.respond(to: "Transcript:\n\(part)", generating: ChapterPlan.self)
            for idea in plan.content.chapters {
                guard let seconds = seconds(from: idea.start) else { continue }
                // Snap to the nearest real line start.
                let start = cues.min { abs($0.start - seconds) < abs($1.start - seconds) }?.start ?? seconds
                found.append(Transcript.Chapter(start: start, title: idea.title.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
            progress(Double(index + 1) / Double(parts.count))
        }
        return tidy(found, duration: transcript.duration ?? cues.last?.end ?? 0)
    }

    /// In order, no near-duplicates (chapters at least 30 s, or 10 % of a short video, apart),
    /// and starting at 0:00 as players expect.
    static func tidy(_ chapters: [Transcript.Chapter], duration: Double) -> [Transcript.Chapter] {
        let minimum = min(30, max(duration * 0.1, 5))
        var result: [Transcript.Chapter] = []
        for chapter in chapters.sorted(by: { $0.start < $1.start }) where !chapter.title.isEmpty {
            if let last = result.last, chapter.start - last.start < minimum { continue }
            result.append(chapter)
        }
        if var first = result.first, first.start > 0 {
            if first.start < minimum { first.start = 0; result[0] = first }
            else { result.insert(Transcript.Chapter(start: 0, title: String(localized: "Intro")), at: 0) }
        }
        return result
    }

    private static func chunks(of lines: [String], size: Int) -> [String] {
        var parts: [String] = []
        var current: [String] = []
        var count = 0
        for line in lines {
            let words = line.split(separator: " ").count
            if count + words > size, !current.isEmpty {
                parts.append(current.joined(separator: "\n"))
                current = []
                count = 0
            }
            current.append(line)
            count += words
        }
        if !current.isEmpty { parts.append(current.joined(separator: "\n")) }
        return parts
    }

    static func clock(_ seconds: Double) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
    }

    static func seconds(from clock: String) -> Double? {
        let parts = clock.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).split(separator: ":").compactMap { Double($0) }
        guard !parts.isEmpty, parts.count <= 3 else { return nil }
        return parts.reduce(0) { $0 * 60 + $1 }
    }
}
