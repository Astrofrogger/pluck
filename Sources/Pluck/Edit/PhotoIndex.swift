import Foundation
import ImageIO
import NaturalLanguage
import Vision

/// What's in each photo in the watched folders, so Search finds them: what Vision on this Mac
/// recognises in the picture (in English words), any text in it, and when it was taken.
@MainActor
@Observable
final class PhotoIndex {
    static let shared = PhotoIndex()

    struct Entry: Codable, Sendable {
        var labels: [String]
        var text: String
        var taken: Date?
        /// The file's date when it was looked at: looked at again when the photo changes.
        var stamp: Date
    }

    private(set) var entries: [String: Entry] = [:]
    private(set) var working: String?
    private(set) var queued = 0
    @ObservationIgnored private var queue: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var saveScheduled = false

    nonisolated private static var file: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Photo Index/index.json")
    }

    private init() {
        if let data = try? Data(contentsOf: Self.file), let saved = try? JSONDecoder().decode([String: Entry].self, from: data) {
            entries = saved
        }
    }

    var count: Int { entries.count }

    /// Photos not looked at yet (or changed since) are queued.
    func enqueue(_ paths: [String]) {
        for path in paths where !queue.contains(path) {
            let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            if let entry = entries[path], entry.stamp >= stamp { continue }
            queue.append(path)
        }
        queued = queue.count
        run()
    }

    private func run() {
        guard task == nil, !queue.isEmpty else { return }
        task = Task {
            while !queue.isEmpty, !Task.isCancelled {
                let path = queue.removeFirst()
                queued = queue.count
                working = URL(fileURLWithPath: path).lastPathComponent
                if let entry = await Task.detached(priority: .utility, operation: { Self.look(at: path) }).value {
                    entries[path] = entry
                    scheduleSave()
                }
            }
            working = nil
            task = nil
        }
    }

    private func scheduleSave() {
        guard !saveScheduled else { return }
        saveScheduled = true
        Task {
            try? await Task.sleep(for: .seconds(3))
            saveScheduled = false
            let snapshot = entries
            await Task.detached(priority: .utility) {
                try? FileManager.default.createDirectory(at: Self.file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? JSONEncoder().encode(snapshot).write(to: Self.file, options: .atomic)
            }.value
        }
    }

    /// Vision's labels and the text in the photo, from a smaller copy (quick, and enough).
    nonisolated private static func look(at path: String) -> Entry? {
        let url = URL(fileURLWithPath: path) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 1024,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let classify = VNClassifyImageRequest()
        let read = VNRecognizeTextRequest()
        read.recognitionLevel = .fast
        try? VNImageRequestHandler(cgImage: image).perform([classify, read])
        let labels = (classify.results ?? []).filter { $0.confidence > 0.25 }.prefix(12).map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
        let text = (read.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ")
        var taken: Date?
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
           let original = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
            taken = formatter.date(from: original)
        }
        let stamp = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .now
        return Entry(labels: Array(labels), text: text, taken: taken, stamp: stamp)
    }

    // MARK: - Searching

    struct Hit: Identifiable, Hashable, Sendable {
        let path: String
        let labels: [String]
        var id: String { path }
    }

    /// What each photo shows, as a sentence's meaning (made once per photo, when searched).
    @ObservationIgnored private var meanings: [String: [Double]] = [:]
    @ObservationIgnored private lazy var sentences = NLEmbedding.sentenceEmbedding(for: .english)

    /// Photos whose labels, text or file name hold the words, or that show what the words mean
    /// ("coast" finds a beach). `english` is the question in English, when it was asked in
    /// another language (Vision names what it sees in English).
    func search(_ words: [String], english: String? = nil, within paths: Set<String>? = nil) -> [Hit] {
        var terms = words.map(Self.normalized).filter { $0.count > 1 }
        if let english { terms += english.split(separator: " ").map { Self.normalized(String($0)) }.filter { $0.count > 1 } }
        terms = Array(Set(terms))
        guard !terms.isEmpty else { return [] }
        let sentence = english ?? words.joined(separator: " ")
        let question = sentences?.vector(for: sentence.lowercased())
        return entries.compactMap { path, entry -> (Hit, Double)? in
            if let paths, !paths.contains(path) { return nil }
            let haystack = Self.normalized(entry.labels.joined(separator: " ") + " " + entry.text + " " + URL(fileURLWithPath: path).lastPathComponent)
            var score = Double(terms.filter { haystack.contains($0) }.count) / Double(terms.count)
            if let question, !entry.labels.isEmpty, let meaning = meaning(of: path, entry) {
                score += Self.cosine(question, meaning) * 1.2
            }
            return score > 0.47 ? (Hit(path: path, labels: entry.labels), score) : nil
        }
        .sorted { $0.1 > $1.1 }
        .prefix(80)
        .map(\.0)
    }

    private func meaning(of path: String, _ entry: Entry) -> [Double]? {
        if let known = meanings[path] { return known }
        let vector = sentences?.vector(for: "a photo of " + entry.labels.prefix(6).joined(separator: ", "))
        meanings[path] = vector
        return vector
    }

    private static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var dot = 0.0, na = 0.0, nb = 0.0
        for (x, y) in zip(a, b) { dot += x * y; na += x * x; nb += y * y }
        return na > 0 && nb > 0 ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    }

    nonisolated static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
    }
}
