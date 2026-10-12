import Foundation
import UniformTypeIdentifiers

/// Finds files by name or title: downloads in the Library, everything in the watched folders,
/// and every transcribed file. Every word typed has to be in the name (accents and capitals
/// don't matter; a letter off is fine in longer words).
@MainActor
enum FileSearch {
    struct Hit: Identifiable, Hashable {
        let path: String
        let title: String
        let isVideo: Bool
        let transcribed: Bool
        let available: Bool
        var id: String { path }
    }

    static func find(_ query: String, within scope: Set<String>? = nil) -> [Hit] {
        let words = normalized(query).split(separator: " ").map(String.init).filter { $0.count > 1 }
        guard !words.isEmpty else { return [] }
        var titles: [String: String] = [:]
        for entry in LibraryStore.shared.entries { titles[entry.path] = entry.title }
        for path in FootageFolders.shared.allVideos + FootageFolders.shared.allPhotos where titles[path] == nil {
            titles[path] = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        }
        var transcribed: Set<String> = []
        for transcript in TranscriptStore.all() {
            transcribed.insert(transcript.filePath)
            if titles[transcript.filePath] == nil { titles[transcript.filePath] = transcript.title }
        }
        return titles.compactMap { path, title -> Hit? in
            if let scope, !scope.contains(path) { return nil }
            let name = normalized(title + " " + URL(fileURLWithPath: path).lastPathComponent)
            let tokens = name.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
            guard words.allSatisfy({ word in name.contains(word) || (word.count >= 5 && tokens.contains { close($0, word) }) }) else { return nil }
            let type = UTType(filenameExtension: URL(fileURLWithPath: path).pathExtension)
            return Hit(path: path, title: title, isVideo: type?.conforms(to: .movie) ?? false,
                       transcribed: transcribed.contains(path), available: FileManager.default.fileExists(atPath: path))
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        .prefix(60)
        .map { $0 }
    }

    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }

    /// One letter off at most.
    private static func close(_ a: String, _ b: String) -> Bool {
        guard abs(a.count - b.count) <= 1 else { return false }
        let x = Array(a), y = Array(b)
        var i = 0, j = 0, edits = 0
        while i < x.count, j < y.count {
            if x[i] == y[j] { i += 1; j += 1; continue }
            edits += 1
            if edits > 1 { return false }
            if x.count > y.count { i += 1 } else if y.count > x.count { j += 1 } else { i += 1; j += 1 }
        }
        return edits + (x.count - i) + (y.count - j) <= 1
    }
}
