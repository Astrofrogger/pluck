import AppKit
import AVFoundation
import CryptoKit
import Foundation

enum StemError: LocalizedError {
    case modelMissing, setupFailed, emptyAudio, download, checksum, model(String)

    var errorDescription: String? {
        switch self {
        case .modelMissing: String(localized: "The stem model isn’t downloaded.")
        case .setupFailed: String(localized: "Stem separation couldn’t start on this Mac.")
        case .emptyAudio: String(localized: "This file has no sound to separate.")
        case .download: String(localized: "The stem model couldn’t be downloaded. Check your internet connection and try again.")
        case .checksum: String(localized: "The downloaded stem model didn’t match its published checksum, so it was discarded.")
        case .model(let detail): String(localized: "Stem separation failed: \(detail)")
        }
    }
}

/// Stem separation (vocals, drums, bass, other, and a karaoke version) with HTDemucs running on
/// this Mac's GPU through Core AI: local AI, nothing uploaded. Needs macOS 27 on Apple silicon.
/// The model (168 MB) isn't part of the app; it's downloaded the first time and checked.
enum Stems {
    static let modelSize: Int64 = 168_496_319
    private static let repository = "https://huggingface.co/arraypress/stems-demucs/resolve/fa4fdc9a42f22056055a046cf12c483f7558ca47/stems-htdemucs-float32.aimodel/"
    /// The model's files, with the SHA-256 of the big one (the others are tiny and inside the
    /// same pinned revision).
    private static let files: [(name: String, sha256: String?)] = [
        ("main.mlirb", "aaa4ae78898df49d1e233c34aed076d475bcd97325f51418bb283fa64f042478"),
        ("main.hash", nil),
        ("metadata.json", nil),
    ]

    static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    static var isSupported: Bool {
        guard #available(macOS 27, *) else { return false }
        return isAppleSilicon
    }

    static var unavailableReason: String? {
        guard #available(macOS 27, *) else { return String(localized: "Needs macOS 27 or later.") }
        return isAppleSilicon ? nil : String(localized: "Needs a Mac with Apple silicon.")
    }

    static var modelFolder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Models/stems-htdemucs-float32.aimodel", isDirectory: true)
    }

    static var isModelInstalled: Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: modelFolder.appendingPathComponent($0.name).path) }
    }

    static func removeModel() {
        try? FileManager.default.removeItem(at: modelFolder)
    }

    /// Downloads the model into place (into a temporary folder first, so a half download never
    /// counts as installed).
    static func installModel(progress: @escaping @Sendable (Double) -> Void) async throws {
        if isModelInstalled { return }
        let staging = modelFolder.deletingLastPathComponent().appendingPathComponent(".download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        for file in files {
            guard let url = URL(string: repository + file.name) else { throw StemError.download }
            let delegate = DownloadProgress(total: file.sha256 == nil ? nil : modelSize, report: progress)
            let (temp, response) = try await URLSession.shared.download(from: url, delegate: delegate)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw StemError.download }
            if let expected = file.sha256 {
                guard try sha256(of: temp) == expected else { throw StemError.checksum }
            }
            try FileManager.default.moveItem(at: temp, to: staging.appendingPathComponent(file.name))
        }
        try? FileManager.default.removeItem(at: modelFolder)
        try FileManager.default.moveItem(at: staging, to: modelFolder)
    }

    private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private final class DownloadProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let total: Int64?
        let report: @Sendable (Double) -> Void
        init(total: Int64?, report: @escaping @Sendable (Double) -> Void) {
            self.total = total
            self.report = report
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                        totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
            guard let total, total > 0 else { return }
            report(min(Double(totalBytesWritten) / Double(total), 1))
        }
        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    }

    /// Separates a raw 44.1 kHz stereo float file (what the model works at) into the stems and
    /// the Instrumental (everything but the vocals: karaoke) as AAC files in a new `folder`, a
    /// chunk at a time: each finished stretch goes straight into the files, so memory stays the
    /// same however long the recording is. Each file gets its name once all are whole.
    @available(macOS 27, *)
    static func separate(_ raw: URL, into folder: URL, progress: @escaping (Double) -> Void,
                         model: ([[Float]]) async throws -> [[[Float]]]) async throws {
        let input = try FileHandle(forReadingFrom: raw)
        defer { try? input.close() }
        let length = Int(try input.seekToEnd()) / 8
        guard length > 1 else { throw StemError.emptyAudio }
        let names = outputs.enumerated().map { "\($0.offset + 1) \($0.element.name).m4a" } + ["5 \(String(localized: "Instrumental (karaoke)")).m4a"]
        let targets = names.map { folder.appendingPathComponent($0) }
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var finished = false
        defer {
            if !finished {
                for target in targets { try? FileManager.default.removeItem(at: EditorExport.partial(target)) }
                rmdir(folder.path)   // only when empty
            }
        }
        let settings: [String: Any] = [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 2,
                                       AVEncoderBitRateKey: 256_000]
        let files = try targets.map {
            try AVAudioFile(forWriting: EditorExport.partial($0), settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        }
        let order = outputs.compactMap { output in DemucsSeparator.sources.firstIndex(of: output.source) }
        // Each chunk's reads and writes let go of what Foundation kept for them (autoreleased),
        // or memory still grows with the length.
        try await DemucsSeparator.separateAt44k(length: length, read: { start, count in try autoreleasepool {
            try input.seek(toOffset: UInt64(start * 8))
            let data = try input.read(upToCount: count * 8) ?? Data()
            let frames = data.count / 8
            var left = [Float](repeating: 0, count: frames), right = [Float](repeating: 0, count: frames)
            data.withUnsafeBytes { buffer in
                let samples = buffer.bindMemory(to: Float.self)
                for i in 0..<frames {
                    left[i] = samples[2 * i]
                    right[i] = samples[2 * i + 1]
                }
            }
            return [left, right]
        } }, write: { stems in try autoreleasepool {
            for (file, stereo) in zip(files, order.map { stems[$0] } + [AIStudio.mix(stems, without: "vocals")]) {
                let count = stereo[0].count
                guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(count)),
                      let channels = buffer.floatChannelData else { throw StemError.setupFailed }
                buffer.frameLength = AVAudioFrameCount(count)
                for ch in 0..<2 { stereo[ch].withUnsafeBufferPointer { channels[ch].update(from: $0.baseAddress!, count: count) } }
                try file.write(from: buffer)
            }
        } }, progress: progress, model: model)
        for file in files { file.close() }
        for target in targets { try FileManager.default.moveItem(at: EditorExport.partial(target), to: target) }
        finished = true
    }

    /// The stems, in the order and names they're saved under.
    static let outputs: [(source: String, name: String)] = [
        ("vocals", String(localized: "Vocals")), ("drums", String(localized: "Drums")),
        ("bass", String(localized: "Bass")), ("other", String(localized: "Other")),
    ]
}

extension AIStudio {
    /// Splits a song (or a video's sound) into Vocals, Drums, Bass, Other and an Instrumental
    /// (everything but the vocals: karaoke), in a folder next to it.
    func separateStems(_ item: DownloadItem) {
        guard #available(macOS 27, *), Stems.isSupported, let file = item.existingFile, item.aiStatus == nil else { return }
        enqueue(item) { [self] in
            item.aiStatus = String(localized: "Preparing…")
            item.aiProgress = nil
            do {
                if !Stems.isModelInstalled {
                    item.aiStatus = String(localized: "Downloading stem model…")
                    try await Stems.installModel { progress in Task { @MainActor in item.aiProgress = progress } }
                }
                item.aiStatus = String(localized: "Reading sound…")
                item.aiProgress = nil
                let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-stems-\(UUID().uuidString).f32")
                defer { try? FileManager.default.removeItem(at: raw) }
                try await ffmpeg(["-y", "-v", "error", "-i", file.path, "-vn", "-ac", "2", "-ar", "44100", "-f", "f32le", raw.path],
                                 failure: StemError.emptyAudio)
                item.aiStatus = String(localized: "Separating stems…")
                item.aiProgress = 0
                let separator = try await DemucsSeparator(contentsOf: Stems.modelFolder)
                let folder = Converting.outputFolder(in: file.deletingLastPathComponent(),
                                                     name: file.deletingPathExtension().lastPathComponent + String(localized: " (stems)"))
                try await Stems.separate(raw, into: folder) { progress in
                    Task { @MainActor in item.aiProgress = progress }
                } model: { try await separator.separateSegment($0) }
                item.aiStatus = nil
                item.aiProgress = nil
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch is CancellationError {
            } catch {
                item.aiStatus = nil
                item.aiProgress = nil
                presentStemError(error, for: item)
            }
        }
    }

    /// All stems added together except one: the karaoke track.
    @available(macOS 27, *)
    nonisolated static func mix(_ stems: [[[Float]]], without excluded: String) -> [[Float]] {
        let kept = DemucsSeparator.sources.indices.filter { DemucsSeparator.sources[$0] != excluded && $0 < stems.count }
        return (0..<2).map { channel in
            var sum = [Float](repeating: 0, count: stems.first?[channel].count ?? 0)
            for source in kept {
                let samples = stems[source][channel]
                for i in sum.indices where i < samples.count { sum[i] += samples[i] }
            }
            return sum
        }
    }

    private func presentStemError(_ error: Error, for item: DownloadItem) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(item.title)” couldn’t be separated")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
