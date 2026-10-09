import AppKit
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
        item.aiStatus = String(localized: "Preparing…")
        item.aiProgress = nil
        Task {
            do {
                if !Stems.isModelInstalled {
                    item.aiStatus = String(localized: "Downloading stem model…")
                    try await Stems.installModel { progress in Task { @MainActor in item.aiProgress = progress } }
                }
                item.aiStatus = String(localized: "Reading sound…")
                item.aiProgress = nil
                let stereo = try await decodeStereo(file)
                item.aiStatus = String(localized: "Separating stems…")
                item.aiProgress = 0
                let separator = try await DemucsSeparator(contentsOf: Stems.modelFolder)
                let stems = try await separator.separateAt44k(stereo) { progress in
                    Task { @MainActor in item.aiProgress = progress }
                }
                item.aiStatus = String(localized: "Saving stems…")
                item.aiProgress = nil
                let folder = Converting.outputURL(folder: file.deletingLastPathComponent().path,
                                                  name: file.deletingPathExtension().lastPathComponent + String(localized: " (stems)"),
                                                  fileExtension: "").deletingPathExtension()
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                for (index, output) in Stems.outputs.enumerated() {
                    guard let stem = DemucsSeparator.sources.firstIndex(of: output.source).map({ stems[$0] }) else { continue }
                    try await encode(stem, to: folder.appendingPathComponent("\(index + 1) \(output.name).m4a"))
                }
                // Karaoke: everything except the vocals, summed back together.
                let instrumental = (0..<2).map { channel in
                    (0..<stems[0][channel].count).map { i in
                        DemucsSeparator.sources.indices.filter { DemucsSeparator.sources[$0] != "vocals" }
                            .reduce(Float(0)) { $0 + stems[$1][channel][i] }
                    }
                }
                try await encode(instrumental, to: folder.appendingPathComponent("5 \(String(localized: "Instrumental (karaoke)")).m4a"))
                item.aiStatus = nil
                item.aiProgress = nil
                NSWorkspace.shared.activateFileViewerSelecting([folder])
            } catch {
                item.aiStatus = nil
                item.aiProgress = nil
                presentStemError(error, for: item)
            }
        }
    }

    /// The sound as 44.1 kHz stereo floats, what the model works at.
    private func decodeStereo(_ file: URL) async throws -> [[Float]] {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-stems-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        try await ffmpeg(["-y", "-v", "error", "-i", file.path, "-vn", "-ac", "2", "-ar", "44100", "-f", "f32le", raw.path],
                         failure: StemError.emptyAudio)
        let data = try Data(contentsOf: raw)
        let frames = data.count / 8
        guard frames > 0 else { throw StemError.emptyAudio }
        var left = [Float](repeating: 0, count: frames), right = [Float](repeating: 0, count: frames)
        data.withUnsafeBytes { buffer in
            let samples = buffer.bindMemory(to: Float.self)
            for i in 0..<frames {
                left[i] = samples[2 * i]
                right[i] = samples[2 * i + 1]
            }
        }
        return [left, right]
    }

    /// Writes one stem as AAC (256 kbps) through ffmpeg.
    private func encode(_ stereo: [[Float]], to output: URL) async throws {
        let raw = FileManager.default.temporaryDirectory.appendingPathComponent("pluck-stem-\(UUID().uuidString).f32")
        defer { try? FileManager.default.removeItem(at: raw) }
        var interleaved = [Float](repeating: 0, count: stereo[0].count * 2)
        for i in 0..<stereo[0].count {
            interleaved[2 * i] = stereo[0][i]
            interleaved[2 * i + 1] = stereo[1][i]
        }
        try interleaved.withUnsafeBufferPointer { try Data(buffer: $0).write(to: raw) }
        try await ffmpeg(["-y", "-v", "error", "-f", "f32le", "-ar", "44100", "-ac", "2", "-i", raw.path,
                          "-c:a", "aac", "-b:a", "256k", output.path], failure: StemError.emptyAudio)
    }

    private func presentStemError(_ error: Error, for item: DownloadItem) {
        let alert = NSAlert()
        alert.messageText = String(localized: "“\(item.title)” couldn’t be separated")
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.runModal()
    }
}
