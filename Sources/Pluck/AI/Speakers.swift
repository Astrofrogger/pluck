import FluidAudio
import Foundation

/// Who said what: an on-device speaker model (NVIDIA's Sortformer, run through FluidAudio) marks
/// when each voice speaks. Up to four speakers; they're numbered in the order they first speak.
enum Speakers {
    /// The model's repository, pinned to a reviewed commit so a changed upload can't slip in.
    private static let repository = "FluidInference/diar-streaming-sortformer-coreml"
    private static let revision = "ae9a27ab45dc0aa3abede7d2d6bad2b7a69aa6d1"

    static var folder: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Pluck/Models/Speakers", isDirectory: true)
    }

    /// The model runs on Apple silicon.
    static var isSupported: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    enum Failure: LocalizedError {
        case unsupported

        var errorDescription: String? {
            String(localized: "Telling speakers apart needs a Mac with Apple silicon.")
        }
    }

    /// Speaker turns in a 16 kHz mono WAV (see `AIStudio.extractAudio`). Downloads the model the
    /// first time (about 230 MB).
    static func turns(in audio: URL, progress: @escaping @Sendable (Double) -> Void) async throws -> [Transcript.SpeakerTurn] {
        guard isSupported else { throw Failure.unsupported }
        ModelRegistry.revisionOverrides[repository] = revision
        let config = SortformerConfig.default
        let models = try await SortformerModels.loadFromHuggingFace(config: config, cacheDirectory: folder)
        let samples = try AudioConverter(sampleRate: Double(config.sampleRate)).resampleAudioFile(audio)
        let diarizer = SortformerDiarizer(config: config)
        diarizer.initialize(models: models)
        let timeline = try diarizer.processComplete(samples) { done, total, _ in
            if total > 0 { progress(Double(done) / Double(total)) }
        }
        var raw: [(start: Double, end: Double, slot: Int)] = []
        for (slot, speaker) in timeline.speakers {
            for segment in speaker.finalizedSegments + speaker.tentativeSegments where segment.duration > 0.2 {
                raw.append((Double(segment.startTime), Double(segment.startTime + segment.duration), slot))
            }
        }
        return numbered(raw)
    }

    /// Turns in time order, speakers renumbered 1, 2, 3… by when they first speak.
    static func numbered(_ raw: [(start: Double, end: Double, slot: Int)]) -> [Transcript.SpeakerTurn] {
        var numbers: [Int: Int] = [:]
        return raw.sorted { $0.start < $1.start }.map { turn in
            let number = numbers[turn.slot] ?? (numbers.count + 1)
            numbers[turn.slot] = number
            return Transcript.SpeakerTurn(s: turn.start, e: turn.end, speaker: number)
        }
    }
}

extension AIStudio {
    /// Adds speaker turns to a transcript (and saves it), from the file's sound.
    @available(macOS 26, *)
    func addSpeakers(to transcript: inout Transcript, file: URL, item: DownloadItem?) async throws {
        item?.aiStatus = String(localized: "Telling speakers apart…")
        item?.aiProgress = nil
        let audio = try await extractAudio(from: file)
        defer { try? FileManager.default.removeItem(at: audio) }
        let turns = try await Task.detached(priority: .userInitiated) {
            try await Speakers.turns(in: audio) { progress in
                Task { @MainActor in item?.aiProgress = progress }
            }
        }.value
        transcript.speakerTurns = turns
        TranscriptStore.save(transcript)
    }
}
