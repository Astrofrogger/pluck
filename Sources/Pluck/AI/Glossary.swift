import Foundation

/// The names local AI should spell right: people, companies, products, places. They're given to
/// the speech recogniser as words to expect, and anything transcribed that's close to one (a
/// letter off, split in two, the wrong capitals) is written the way it's listed here.
@MainActor
@Observable
final class Glossary {
    static let shared = Glossary()
    nonisolated static let key = "glossaryTerms"

    private(set) var terms: [String] = UserDefaults.standard.stringArray(forKey: key) ?? []

    /// Adds names typed together, separated by commas or new lines.
    func add(_ typed: String) {
        for name in typed.split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == ";" }) {
            let name = name.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !terms.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) else { continue }
            terms.append(name)
        }
        save()
    }

    func remove(_ term: String) {
        terms.removeAll { $0 == term }
        save()
    }

    private func save() {
        UserDefaults.standard.set(terms, forKey: Self.key)
    }

    /// The names, from any thread (transcribing runs in the background).
    nonisolated static var current: [String] { UserDefaults.standard.stringArray(forKey: key) ?? [] }

    // MARK: - Correcting

    /// Transcribed words with the names written right, keeping their timing: words that together
    /// spell a name become one word spanning their time.
    nonisolated static func correct(_ words: [Transcript.Word], terms: [String] = current) -> [Transcript.Word] {
        let names = prepared(terms)
        guard !names.isEmpty, !words.isEmpty else { return words }
        var result: [Transcript.Word] = []
        var index = 0
        while index < words.count {
            if let (name, count) = match(at: index, in: words.map(\.t), names: names) {
                let first = words[index], last = words[index + count - 1]
                let (lead, _, _) = split(first.t)
                let (_, _, trail) = split(last.t)
                result.append(Transcript.Word(s: first.s, e: last.e, t: lead + name + trail))
                index += count
            } else {
                result.append(words[index])
                index += 1
            }
        }
        return result
    }

    /// A line of text with the names written right.
    nonisolated static func correct(_ text: String, terms: [String] = current) -> String {
        let names = prepared(terms)
        guard !names.isEmpty else { return text }
        return text.components(separatedBy: "\n").map { line in
            let tokens = line.split(separator: " ", omittingEmptySubsequences: false).enumerated().map { $0.offset == 0 ? String($0.element) : " " + $0.element }
            var out = ""
            var index = 0
            while index < tokens.count {
                if let (name, count) = match(at: index, in: tokens, names: names) {
                    let (lead, _, _) = split(tokens[index])
                    let (_, _, trail) = split(tokens[index + count - 1])
                    out += lead + name + trail
                    index += count
                } else {
                    out += tokens[index]
                    index += 1
                }
            }
            return out
        }.joined(separator: "\n")
    }

    private struct Name {
        let written: String
        let key: String
        let words: Int
    }

    nonisolated private static func prepared(_ terms: [String]) -> [Name] {
        terms.map { Name(written: $0, key: normalized($0), words: $0.split(separator: " ").count) }
            .filter { $0.key.count >= 2 }
            // Longer names first, so "Northwind Studios" wins over "Northwind".
            .sorted { $0.key.count > $1.key.count }
    }

    /// The name that the words from here spell (allowing one word more or fewer), and how many words it takes.
    nonisolated private static func match(at index: Int, in tokens: [String], names: [Name]) -> (String, Int)? {
        for name in names {
            for count in [name.words, name.words + 1, name.words - 1] where count >= 1 && index + count <= tokens.count {
                let parts = tokens[index..<index + count].map(split)
                let window = parts.map(\.core)
                // Something has to be there (no names out of punctuation), and a name doesn't run
                // across a comma or the end of a sentence.
                guard window.allSatisfy({ !$0.isEmpty }),
                      parts.dropLast().allSatisfy({ $0.trail.isEmpty || $0.trail == "-" }) else { continue }
                let spelled = normalized(window.joined())
                if spelled == name.key { return (name.written, count) }
                // Close enough: a letter off in a name of five letters or more, two in one of eight.
                if name.key.count >= 5, abs(spelled.count - name.key.count) <= 2,
                   distance(spelled, name.key) <= (name.key.count >= 8 ? 2 : 1) {
                    return (name.written, count)
                }
            }
        }
        return nil
    }

    /// A word split into what's before it (spaces, quotes), the word, and what's after (punctuation).
    nonisolated private static func split(_ token: String) -> (lead: String, core: String, trail: String) {
        let characters = Array(token)
        var start = 0, end = characters.count
        while start < end, !(characters[start].isLetter || characters[start].isNumber) { start += 1 }
        while end > start, !(characters[end - 1].isLetter || characters[end - 1].isNumber) { end -= 1 }
        return (String(characters[..<start]), String(characters[start..<end]), String(characters[end...]))
    }

    /// Lower case, no accents, letters and digits only.
    nonisolated private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil).filter { $0.isLetter || $0.isNumber }
    }

    nonisolated private static func distance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        guard !a.isEmpty else { return b.count }
        guard !b.isEmpty else { return a.count }
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
}
