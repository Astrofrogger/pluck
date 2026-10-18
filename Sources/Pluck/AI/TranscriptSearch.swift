import Foundation
import FoundationModels
import NaturalLanguage
import Translation

/// Search inside videos: finds the moments in transcripts that match a question, in any of the
/// languages they were spoken in.
///
/// Keyword ranking (BM25 over word roots, so "editing" finds "editor") does the fast first pass
/// over every transcript and the translations made of them. The question is also translated on
/// this Mac into each language the transcripts are in, so an English or Dutch question finds a
/// French interview. With Apple Intelligence, local AI widens the question into the words people
/// would actually say (in those languages too), then reads the best candidates and keeps the
/// ones that answer it. Everything runs on this Mac.
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
        /// The file is there (not on a drive that's unplugged).
        let available: Bool
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
    /// The languages spoken in the transcripts ("fr", "nl"…).
    private var languages: Set<String> = []
    /// Questions already translated: "nl→fr:vieze toiletten".
    private var translatedQuestions: [String: String] = [:]

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
            // Also transcripts of files that aren't there right now (a drive that's unplugged):
            // they're found, and marked.
            let all = TranscriptStore.all()
            var passages: [Passage] = []
            for (index, transcript) in all.enumerated() {
                let language = NLLanguage(Locale(identifier: transcript.language).language.languageCode?.identifier ?? "en")
                // About 20 seconds of speech per passage: enough context, still a precise jump.
                // The translations made of it are searched along, with the same timing.
                let versions: [(NLLanguage, [(Double, Double, String)])] =
                    [(language, transcript.cues().map { ($0.start, $0.end, $0.text) })]
                    + (transcript.translations ?? [:]).map { code, translation in (NLLanguage(code), translation.lines.map { ($0.s, $0.e, $0.t) }) }
                for (lang, lines) in versions {
                    var text = "", start = 0.0
                    for line in lines {
                        if text.isEmpty { start = line.0 }
                        text += (text.isEmpty ? "" : " ") + line.2
                        if line.1 - start >= 20 {
                            passages.append(Passage(transcript: index, start: start, text: text, roots: Self.roots(text, language: lang)))
                            text = ""
                        }
                    }
                    if !text.isEmpty { passages.append(Passage(transcript: index, start: start, text: text, roots: Self.roots(text, language: lang))) }
                }
            }
            return (all, passages)
        }.value
        transcripts = built.0
        passages = built.1
        languages = Set(transcripts.map { Locale(identifier: $0.language).language.languageCode?.identifier ?? $0.language })
        documentFrequency = [:]
        for passage in passages { for root in Set(passage.roots) { documentFrequency[root, default: 0] += 1 } }
        averageLength = max(Double(passages.map(\.roots.count).reduce(0, +)) / Double(max(passages.count, 1)), 1)
        indexedFiles = stamps
    }

    /// The moments that answer a question. `within`: only files in these folders (a scope).
    /// `quick`: the words as typed, without translating them or asking for related words (for
    /// searching as you type).
    func search(_ query: String, within folders: [String] = [], quick: Bool = false) async -> [Hit] {
        await refresh()
        let question = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !passages.isEmpty else { return [] }
        let language = Self.language(of: question)
        var terms = Self.roots(question, language: language)
        var highlightWords = question.split(separator: " ").map(String.init)

        // The question in the other languages spoken in the transcripts, translated on this Mac.
        let asked = language.rawValue
        for target in languages where target != asked && !quick {
            if let translated = await translate(question, from: asked, to: target) {
                terms += Self.roots(translated, language: NLLanguage(target))
                highlightWords += translated.split(separator: " ").map(String.init)
            }
        }

        if #available(macOS 26, *), LocalAI.canSummarize, !quick {
            let aiWords = (try? await Self.expand(question, languages: Array(languages))) ?? []
            terms += aiWords.flatMap { word in
                // Roots in whichever language the word is in.
                Self.roots(word, language: Self.language(of: word))
            }
            highlightWords += aiWords
        }
        terms = Array(Set(terms.filter { !Self.stopWords.contains($0) }))
        guard !terms.isEmpty else { return [] }

        let scope = folders.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        let ranked = passages.indices
            .filter { index in
                let path = transcripts[passages[index].transcript].filePath
                return scope.isEmpty || scope.contains { path.hasPrefix($0) }
            }
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
        let highlight = highlightWords.filter { $0.count > 2 }
        // One hit per moment: a passage and its translation land on the same spot.
        var seen: Set<String> = []
        var hits: [Hit] = []
        for index in order {
            let passage = passages[index]
            let transcript = transcripts[passage.transcript]
            let key = "\(transcript.id)@\(Int(passage.start))"
            guard seen.insert(key).inserted else { continue }
            hits.append(Hit(transcriptID: transcript.id, title: transcript.title, filePath: transcript.filePath,
                            start: passage.start, text: passage.text, terms: highlight,
                            available: FileManager.default.fileExists(atPath: transcript.filePath)))
            if hits.count == 30 { break }
        }
        return hits
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
    private static func expand(_ question: String, languages: [String]) async throws -> [String] {
        let names = languages.compactMap { Locale(identifier: "en").localizedString(forLanguageCode: $0) }
        let also = names.isEmpty ? "" : " Give them in the language of the question and also in \(names.joined(separator: ", "))."
        let session = LanguageModelSession(instructions: "You turn a question about a video into search words that would appear in what's said in it.\(also)")
        return try await session.respond(to: "Question: \(question)", generating: Expansion.self,
                                         options: GenerationOptions(sampling: .greedy)).content.terms
    }

    /// The question in English (what's seen in videos and photos is written in English), when it
    /// was asked in another language this Mac can translate from; otherwise as asked.
    func english(_ question: String) async -> String {
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let language = Self.language(of: question).rawValue
        guard question.count > 2, !language.hasPrefix("en") else { return question }
        return await translate(question, from: language, to: "en") ?? question
    }

    /// The question in another language, when this Mac has that language pair (macOS 26).
    private func translate(_ question: String, from source: String, to target: String) async -> String? {
        let key = "\(source)→\(target):\(question)"
        if let done = translatedQuestions[key] { return done }
        guard #available(macOS 26, *) else { return nil }
        let from = Locale.Language(identifier: source), to = Locale.Language(identifier: target)
        guard await LanguageAvailability().status(from: from, to: to) == .installed else { return nil }
        let session = TranslationSession(installedSource: from, target: to)
        guard let response = try? await session.translate(question) else { return nil }
        translatedQuestions[key] = response.targetText
        return response.targetText
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
