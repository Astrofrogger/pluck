import AVFoundation
import CryptoKit
import Foundation

/// Social Cutdowns' work on the open edit, kept while the page is away (the page is rebuilt each
/// time it's shown) and saved per source so it's back after a relaunch.
@MainActor @Observable
final class CutdownSession {
    static let shared = CutdownSession()

    var source: URL?
    var analysis: SocialCutdowns.Analysis?
    var plans: [SocialCutdowns.Format: [SocialCutdowns.ShotPlan]] = [:]
    var edits: [Double: SocialCutdowns.ShotEdit] = [:]
    var cues: [Transcript.Cue]?
    /// The transcript the captions came from (in Pluck's transcript store).
    var transcriptID: String?
    var languages: [Locale] = []
    var language: Locale?
    /// The edit as an item in Pluck's list, which the transcript belongs to.
    var item: DownloadItem?
    var folder: URL?
    var status: String?
    var share: Double?
    var problem: String?
    var time = 0.0
    var task: Task<Void, Never>?
    let player = AVPlayer()
    @ObservationIgnored var observer: Any?
    @ObservationIgnored private var saving: Task<Void, Never>?

    /// Writes the analysis, the hand edits and the captions' transcript for this source, shortly
    /// after the last change (a dragged crop changes many times a second).
    func saveSoon() {
        guard let analysis else { return }
        let saved = SocialCutdowns.Saved(analysis: analysis, edits: edits, transcriptID: transcriptID, language: language?.identifier)
        saving?.cancel()
        saving = Task {
            try? await Task.sleep(for: .milliseconds(600))
            guard !Task.isCancelled else { return }
            await Task.detached { saved.write() }.value
        }
    }
}

extension SocialCutdowns {
    /// What's kept for one source: in Pluck's support folder, named after the source's path, and
    /// only used while the source's size and date are the ones it was made from.
    struct Saved: Codable, Sendable {
        var path: String
        var size: Int64
        var modified: Date
        var analysis: Analysis
        var edits: [Double: ShotEdit]
        var transcriptID: String?
        var language: String?

        init(analysis: Analysis, edits: [Double: ShotEdit], transcriptID: String?, language: String?) {
            let file = Self.stamp(analysis.file)
            path = analysis.file.path
            size = file.size
            modified = file.modified
            self.analysis = analysis
            self.edits = edits
            self.transcriptID = transcriptID
            self.language = language
        }

        /// Overridden by the self-test.
        nonisolated(unsafe) static var folder = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Cutdowns", isDirectory: true)

        static func url(for source: URL) -> URL {
            let hash = SHA256.hash(data: Data(source.standardizedFileURL.path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
            return folder.appendingPathComponent(hash + ".json")
        }

        static func stamp(_ file: URL) -> (size: Int64, modified: Date) {
            let values = try? file.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            return (Int64(values?.fileSize ?? -1), values?.contentModificationDate ?? .distantPast)
        }

        func write() {
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            guard let data = try? JSONEncoder().encode(self) else { return }
            try? data.write(to: Self.url(for: URL(fileURLWithPath: path)), options: .atomic)
        }

        /// The saved work for `source`, or nil when there's none or the file changed since.
        static func load(_ source: URL) -> Saved? {
            guard let data = try? Data(contentsOf: url(for: source)),
                  let saved = try? JSONDecoder().decode(Saved.self, from: data), saved.path == source.path else { return nil }
            let now = stamp(source)
            guard now.size == saved.size, abs(now.modified.timeIntervalSince(saved.modified)) < 0.001 else { return nil }
            return saved
        }
    }
}
