import Foundation
import FoundationModels

/// Builds a story from several clips at once: the story finder reads each file's transcript,
/// then local AI puts the passages from all of them in the order that tells the story best (an
/// opening that grabs, what you need to know, the main points, the moving parts, an ending).
/// More files give it more to choose from.
enum ProjectStory {
    struct Passage: Identifiable, Hashable {
        var id: UUID { beat.id }
        var beat: StoryBeat
        var path: String
        var file: String { URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent }
    }

    @available(macOS 26, *)
    @Generable
    struct Order {
        @Guide(description: "The numbers of the passages in the order that tells the story best. Leave out ones that repeat or don't fit.")
        var passages: [Int]
    }

    /// The passages from every file that has a transcript, in story order.
    static func find(in paths: [String], focus: String?, titlesIn language: String?, length: Double = 0,
                     progress: @escaping @Sendable (Double) -> Void) async throws -> [Passage] {
        let transcripts = paths.compactMap { path in TranscriptStore.find(forFile: path).map { (path, $0) } }
        guard !transcripts.isEmpty else { throw StoryFinder.Failure.nothingFound }
        var passages: [Passage] = []
        for (index, (path, transcript)) in transcripts.enumerated() {
            // Each file offers enough to fill the length on its own; the cut comes after the order.
            let beats = (try? await StoryFinder.find(in: transcript, focus: focus, titlesIn: language,
                                                     length: length > 0 ? length * 1.5 : 0) { value in
                progress((Double(index) + value * 0.9) / Double(transcripts.count))
            }) ?? []
            passages += beats.map { Passage(beat: $0, path: path) }
        }
        guard !passages.isEmpty else { throw StoryFinder.Failure.nothingFound }
        let ordered = await order(passages, focus: focus)
        guard length > 0 else { return ordered }
        let kept = Set(StoryFinder.fit(ordered.map(\.beat), to: length).map(\.id))
        return ordered.filter { kept.contains($0.id) }
    }

    /// Local AI's order for the passages; by their part in a story when it can't.
    static func order(_ passages: [Passage], focus: String?) async -> [Passage] {
        let fallback = passages.sorted { a, b in
            let ra = StoryBeat.Role.allCases.firstIndex(of: a.beat.role) ?? 0, rb = StoryBeat.Role.allCases.firstIndex(of: b.beat.role) ?? 0
            return ra != rb ? ra < rb : (a.path, a.beat.start) < (b.path, b.beat.start)
        }
        guard #available(macOS 26, *), LocalAI.canSummarize, passages.count > 2 else { return fallback }
        let listing = passages.enumerated().map { "\($0.offset + 1). [\($0.element.beat.role.rawValue)] \($0.element.beat.title) (from \($0.element.file))" }
            .joined(separator: "\n")
        let topic = focus?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let session = LanguageModelSession(instructions: """
            You are a documentary editor arranging interview passages into one short film. Start \
            with a hook, then context, then the main points, an emotional moment, and end with a \
            line that rounds it off. Mix passages from different interviews where it helps the \
            story.\(topic.isEmpty ? "" : " The film is about: \(topic).")
            """)
        guard let reply = try? await session.respond(to: "Passages:\n\(listing)", generating: Order.self,
                                                     options: GenerationOptions(sampling: .greedy)) else { return fallback }
        var seen: Set<Int> = []
        let ordered = reply.content.passages.compactMap { number -> Passage? in
            guard number >= 1, number <= passages.count, seen.insert(number).inserted else { return nil }
            return passages[number - 1]
        }
        guard ordered.count >= 2 else { return fallback }
        // However the model ordered them: the hook opens and the ending closes.
        let hooks = ordered.filter { $0.beat.role == .hook }, endings = ordered.filter { $0.beat.role == .ending }
        return hooks + ordered.filter { $0.beat.role != .hook && $0.beat.role != .ending } + endings
    }

    /// The passages as clips, with a breath around each.
    static func clips(_ passages: [Passage]) -> [ProjectClip] {
        passages.map {
            ProjectClip(path: $0.path, start: max($0.beat.start - 0.15, 0), end: $0.beat.end + 0.25,
                        fadeIn: 0.05, fadeOut: 0.08, title: $0.beat.title, role: $0.beat.role)
        }
    }
}
