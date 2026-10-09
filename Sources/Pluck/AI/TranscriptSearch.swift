import Foundation
import FoundationModels
import NaturalLanguage

/// Search inside downloads: finds the moments in transcripts that match a question.
///
/// Keyword ranking (BM25 over word roots, so "editing" finds "editor") does the fast first pass
/// over every transcript. With Apple Intelligence, local AI first widens the question into the
/// words people would actually say, then reads the best candidates and keeps the ones that
/// answer it. Everything runs on this Mac.
@MainActor
final class TranscriptSearch {
    struct Hit: Identifiable, Sendable {
        let transcriptID: String
        let title: String
        let filePath: String
        let start: Double
        let text: String
        /// Words to highlight in the snippet.
        let terms: [String]
        var id: String { "\(transcriptID)@\(start)" }
    }

    private struct Passage: Sendable {
        let transcript: Int
        let start: Double
        let text: String
        let roots: [String]
    }

    private var passages: [Passage] = []
    private var transcripts: [Transcript] = []
    private var indexedFiles: [String: Date] = [:]
    private var documentFrequency: [String: Int] = [:]
    private var averageLength = 1.0

    /// How many transcripts there are to search.
    var count: Int { transcripts.count }

    /// Rebuilds the index when transcripts were added or changed since last time.
    func refresh() async {
        let folder = TranscriptStore.folder
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        var stamps: [String: Date] = [:]
        for file in files where file.pathExtension == "json" {
            stamps[file.lastPathComponent] = (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        guard stamps != indexedFiles else { return }
        let built = await Task.detached(priority: .userInitiated) { () -> ([Transcript], [Passage]) in
            let all = TranscriptStore.all().filter { FileManager.default.fileExists(atPath: $0.filePath) }
            var passages: [Passage] = []
            for (index, transcript) in all.enumerated() {
                let language = NLLanguage(Locale(identifier: transcript.language).language.languageCode?.identifier ?? "en")
                // About 20 seconds of speech per passage: enough context, still a precise jump.
                var text = "", start = 0.0
                for cue in transcript.cues() {
                    if text.isEmpty { start = cue.start }
                    text += (text.isEmpty ? "" : " ") + cue.text
                    if cue.end - start >= 20 {
                        passages.append(Passage(transcript: index, start: start, text: text, roots: Self.roots(text, language: language)))
                        text = ""
                    }
                }
                if !text.isEmpty { passages.append(Passage(transcript: index, start: start, text: text, roots: Self.roots(text, language: language))) }
            }
            return (all, passages)
        }.value
        transcripts = built.0
        passages = built.1
        documentFrequency = [:]
        for passage in passages { for root in Set(passage.roots) { documentFrequency[root, default: 0] += 1 } }
        averageLength = max(Double(passages.map(\.roots.count).reduce(0, +)) / Double(max(passages.count, 1)), 1)
        indexedFiles = stamps
    }

    func search(_ query: String) async -> [Hit] {
        await refresh()
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !passages.isEmpty else { return [] }
        let language = Self.language(of: question)
        var terms = Self.roots(question, language: language)

        var aiWords: [String] = []
        if #available(macOS 26, *), LocalAI.canSummarize {
            aiWords = (try? await Self.expand(question)) ?? []
            terms += aiWords.flatMap { Self.roots($0, language: language) }
        }
        terms = Array(Set(terms.filter { !Self.stopWords.contains($0) }))
        guard !terms.isEmpty else { return [] }

        let ranked = passages.indices
            .map { ($0, bm25(passages[$0], terms)) }
            .filter { $0.1 > 0 }
            .sorted { $0.1 > $1.1 }
        var order = ranked.prefix(30).map(\.0)

        if #available(macOS 26, *), LocalAI.canSummarize, !order.isEmpty {
            let candidates = Array(order.prefix(10))
            if let picks = try? await Self.choose(question, among: candidates.map { passages[$0].text }) {
                let chosen = picks.compactMap { $0 >= 1 && $0 <= candidates.count ? candidates[$0 - 1] : nil }
                // The model's picks first, then the other keyword matches.
                order = chosen + order.filter { !chosen.contains($0) }
            }
        }
        let highlight = (question.split(separator: " ").map(String.init) + aiWords).filter { $0.count > 2 }
        return order.prefix(20).map { index in
            let passage = passages[index]
            let transcript = transcripts[passage.transcript]
            return Hit(transcriptID: transcript.id, title: transcript.title, filePath: transcript.filePath,
                       start: passage.start, text: passage.text, terms: highlight)
        }
    }

    private func bm25(_ passage: Passage, _ terms: [String]) -> Double {
        let total = Double(passages.count)
        let length = Double(passage.roots.count)
        return terms.reduce(0) { score, term in
            let frequency = Double(passage.roots.lazy.filter { $0 == term }.count)
            guard frequency > 0 else { return score }
            let df = Double(documentFrequency[term] ?? 0)
            let idf = log(1 + (total - df + 0.5) / (df + 0.5))
            return score + idf * frequency * 2.2 / (frequency + 1.2 * (0.25 + 0.75 * length / averageLength))
        }
    }

    // MARK: - Local AI

    @available(macOS 26, *)
    @Generable
    struct Expansion {
        @Guide(description: "Words and short phrases someone would actually say in the video when talking about this, including synonyms.", .count(4...12))
        var terms: [String]
    }

    @available(macOS 26, *)
    @Generable
    struct Choice {
        @Guide(description: "The numbers of the passages that answer the question, best first. Empty if none do.")
        var passages: [Int]
    }

    @available(macOS 26, *)
    private static func expand(_ question: String) async throws -> [String] {
        let session = LanguageModelSession(instructions: "You turn a question about a video into search words that would appear in what's said in it. Use the language of the question.")
        return try await session.respond(to: "Question: \(question)", generating: Expansion.self).content.terms
    }

    @available(macOS 26, *)
    private static func choose(_ question: String, among texts: [String]) async throws -> [Int] {
        let listing = texts.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n")
        let session = LanguageModelSession(instructions: "You find the passages of video transcripts that answer a question.")
        return try await session.respond(to: "Question: \(question)\n\nPassages:\n\(listing)", generating: Choice.self).content.passages
    }

    // MARK: - Text

    nonisolated static func language(of text: String) -> NLLanguage {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)
        return recognizer.dominantLanguage ?? NLLanguage(Locale.current.language.languageCode?.identifier ?? "en")
    }

    /// Lowercased word roots ("editing" → "edit"), without accents.
    nonisolated static func roots(_ text: String, language: NLLanguage) -> [String] {
        let lowered = text.lowercased()
        let tagger = NLTagger(tagSchemes: [.lemma])
        tagger.string = lowered
        tagger.setLanguage(language, range: lowered.startIndex..<lowered.endIndex)
        var roots: [String] = []
        tagger.enumerateTags(in: lowered.startIndex..<lowered.endIndex, unit: .word, scheme: .lemma,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, range in
            let word = tag?.rawValue ?? String(lowered[range])
            if word.count > 1 { roots.append(word.folding(options: .diacriticInsensitive, locale: nil)) }
            return true
        }
        return roots
    }

    /// Small words that match everything, in the languages Pluck speaks.
    nonisolated static let stopWords: Set<String> = [
        "the", "a", "an", "and", "or", "of", "to", "in", "on", "for", "is", "are", "be", "it", "this", "that", "with",
        "about", "part", "how", "what", "where", "when", "who", "we", "they", "you", "do", "can", "video",
        "de", "het", "een", "en", "van", "in", "op", "is", "dat", "die", "wat", "hoe", "waar", "over",
        "der", "das", "und", "ist", "le", "la", "les", "et", "est", "el", "los", "y", "es", "il", "di", "che",
    ]
}
