import Foundation
import FoundationModels
import SwiftUI

/// A passage of an interview worth building a story with, as an editor would mark it on a paper
/// edit: what it does for the story (the hook, context, a key point, emotion, the ending) and
/// what it's about.
struct StoryBeat: Codable, Identifiable, Hashable, Sendable {
    enum Role: String, Codable, CaseIterable, Sendable {
        case hook, context, point, emotion, ending

        var title: LocalizedStringKey {
            switch self {
            case .hook: "Hook"
            case .context: "Context"
            case .point: "Key Point"
            case .emotion: "Emotion"
            case .ending: "Ending"
            }
        }

        var color: Color {
            switch self {
            case .hook: Design.Brand.pink
            case .context: .teal
            case .point: .blue
            case .emotion: .orange
            case .ending: Design.Brand.violet
            }
        }

        var symbol: String {
            switch self {
            case .hook: "bolt.fill"
            case .context: "map"
            case .point: "key.fill"
            case .emotion: "heart.fill"
            case .ending: "flag.checkered"
            }
        }
    }

    var id = UUID()
    var start: Double
    var end: Double
    var role: Role
    var title: String
    /// Kept for the story edit (unticked ones are left out).
    var kept = true
}

/// Finds the story beats in a transcript with Apple's on-device language model. The transcript
/// is read in parts (the model's context is small); each part offers its strongest passages,
/// then the best are kept, snapped to whole lines and kept apart.
enum StoryFinder {
    @available(macOS 26, *)
    @Generable
    struct Picks {
        @Guide(description: "The passages in this part worth using to tell the story, strongest first.", .count(0...4))
        var beats: [Pick]
    }

    @available(macOS 26, *)
    @Generable
    struct Pick {
        @Guide(description: "Timestamp of the line where the passage starts, exactly as written, like 03:15.")
        var start: String
        @Guide(description: "Timestamp of the last line of the passage, exactly as written.")
        var end: String
        @Guide(description: "What the passage does in the story.", .anyOf(["hook", "context", "point", "emotion", "ending"]))
        var role: String
        // No free sentence ("why it's good"): the model sometimes rambles on in one, which
        // turned seconds into minutes. The title says enough.
        @Guide(description: "What the passage is about, in at most 5 words.")
        var title: String
        @Guide(description: "How strong the passage is for the story, from 1 to 10.", .range(1...10))
        var score: Int
    }

    enum Failure: LocalizedError {
        case needsAppleIntelligence, nothingFound

        var errorDescription: String? {
            switch self {
            case .needsAppleIntelligence: String(localized: "Finding the story needs Apple Intelligence to be turned on.")
            case .nothingFound: String(localized: "Nothing stood out: there's too little speech, or it's all small talk.")
            }
        }
    }

    /// About one passage per minute of speech, between 4 and 16.
    static func wanted(for transcript: Transcript) -> Int {
        let speech = (transcript.words.last?.e ?? 0) - (transcript.words.first?.s ?? 0)
        return min(max(Int(speech / 60), 4), 16)
    }

    /// The story beats, in time order. `focus` steers the choice ("the new building", "pricing").
    static func find(in transcript: Transcript, focus: String? = nil, titlesIn titleLanguage: String? = nil,
                     progress: @escaping @Sendable (Double) -> Void = { _ in }) async throws -> [StoryBeat] {
        guard #available(macOS 26, *), LocalAI.canSummarize else { throw Failure.needsAppleIntelligence }
        let cues = transcript.cues(maxCharacters: 160, maxDuration: 12)
        guard !cues.isEmpty else { throw Failure.nothingFound }
        let lines = cues.map { "[\(OnDeviceWriter.clock($0.start))] \(transcript.speakerLabel(for: $0))\($0.text)" }
        var parts: [[String]] = [[]]
        var words = 0
        for line in lines {
            let count = OnDeviceWriter.size(of: line)
            if words + count > 650, !(parts.last ?? []).isEmpty { parts.append([]); words = 0 }
            parts[parts.count - 1].append(line)
            words += count
        }
        let topic = focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        // Named outright: told only "the transcript's language", the model drifts into English.
        let language = Locale(identifier: "en").localizedString(forLanguageCode: titleLanguage ?? Locale(identifier: transcript.language).language.languageCode?.identifier ?? "en") ?? "English"
        var found: [(StoryBeat, Int)] = []
        for (index, part) in parts.enumerated() {
            let session = LanguageModelSession(instructions: """
                You are a documentary editor reading an interview transcript to make a paper edit. \
                Pick the passages worth using to build a story: a line that grabs attention (hook), \
                what the viewer needs to know (context), the main ideas (point), honest or moving \
                moments (emotion), and lines that round it off (ending). Choose complete thoughts \
                of one to four lines that make sense on their own. Skip small talk, repetition, \
                false starts, questions from the interviewer and anything vague. Write the titles \
                in \(language).\
                \(topic.isEmpty ? "" : " The story is about: \(topic). Prefer passages about that.")
                """)
            // Greedy: the same picks every time, and no wandering off.
            let reply = try await session.respond(to: "Interview: \(transcript.title)\nTranscript:\n\(part.joined(separator: "\n"))",
                                                  generating: Picks.self, options: GenerationOptions(sampling: .greedy))
            for pick in reply.content.beats {
                guard let start = OnDeviceWriter.seconds(from: pick.start), let end = OnDeviceWriter.seconds(from: pick.end) else { continue }
                let beat = StoryBeat(start: start, end: max(end, start), role: StoryBeat.Role(rawValue: pick.role) ?? .point,
                                     title: pick.title)
                found.append((beat, pick.score))
            }
            progress(Double(index + 1) / Double(parts.count))
        }
        let chosen = choose(found, cues: cues, count: wanted(for: transcript))
        guard !chosen.isEmpty else { throw Failure.nothingFound }
        return chosen
    }

    /// The strongest passages, on whole lines, not overlapping, back in time order.
    static func choose(_ found: [(StoryBeat, Int)], cues: [Transcript.Cue], count: Int) -> [StoryBeat] {
        var chosen: [StoryBeat] = []
        for (beat, _) in found.sorted(by: { $0.1 > $1.1 }) {
            guard chosen.count < count else { break }
            // From the start of the line it starts in to the end of the line it ends in.
            guard let first = cues.last(where: { $0.start <= beat.start + 0.5 }) ?? cues.first else { continue }
            let last = cues.last { $0.start <= max(beat.end, first.start) + 0.5 } ?? first
            var snapped = beat
            snapped.start = first.start
            snapped.end = max(last.end, first.end)
            guard snapped.end - snapped.start <= 75,
                  !chosen.contains(where: { $0.start < snapped.end && snapped.start < $0.end }) else { continue }
            chosen.append(snapped)
        }
        return chosen.sorted { $0.start < $1.start }
    }
}

extension Transcript {
    /// "Sam: " before a line, when speakers are known (the model then knows who says what).
    func speakerLabel(for cue: Cue) -> String {
        guard let speaker = cue.speaker else { return "" }
        return speakerName(speaker) + ": "
    }
}
