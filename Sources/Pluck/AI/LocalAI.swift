import AVFoundation
import Foundation
import FoundationModels
import NaturalLanguage
import Speech
import Translation

/// Pluck's local AI: everything here runs on this Mac. Speech recognition, translation and the
/// language model are Apple's on-device frameworks; nothing is uploaded.
enum LocalAI {
    /// Transcripts, subtitles, translation and search (macOS 26 or later).
    static var canTranscribe: Bool {
        guard #available(macOS 26, *) else { return false }
        return SpeechTranscriber.isAvailable
    }

    /// Summaries and chapters, which need Apple Intelligence to be turned on.
    static var canSummarize: Bool {
        guard #available(macOS 26, *) else { return false }
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// Why summaries aren't available, in words people can act on.
    static var summarizeUnavailableReason: String? {
        guard #available(macOS 26, *) else { return String(localized: "Needs macOS 26 or later.") }
        switch SystemLanguageModel.default.availability {
        case .available: return nil
        case .unavailable(.appleIntelligenceNotEnabled):
            return String(localized: "Turn on Apple Intelligence in System Settings to use summaries and chapters.")
        case .unavailable(.deviceNotEligible):
            return String(localized: "This Mac doesn’t support Apple Intelligence, which summaries and chapters need.")
        case .unavailable(.modelNotReady):
            return String(localized: "Apple Intelligence is still getting ready. Try again in a while.")
        default:
            return String(localized: "Apple Intelligence isn’t available right now.")
        }
    }

    enum Failure: LocalizedError {
        case unsupportedLanguage, noSpeech, noAudio, unavailable

        var errorDescription: String? {
            switch self {
            case .unsupportedLanguage: String(localized: "This Mac can’t transcribe that language.")
            case .noSpeech: String(localized: "No speech was found in this file.")
            case .noAudio: String(localized: "Pluck couldn’t read the sound of this file.")
            case .unavailable: String(localized: "Transcripts need macOS 26 or later.")
            }
        }
    }

    /// The supported language closest to a guess: same language and region, then the same
    /// language in the user's region, then the same language anywhere.
    static func match(_ guess: Locale, in supported: [Locale]) -> Locale? {
        // "English" alone means US English, "Dutch" Dutch from the Netherlands, and so on.
        let likely = Locale(identifier: guess.language.maximalIdentifier).region
        return supported.first { $0.identifier == guess.identifier }
            ?? supported.first { $0.language.languageCode == guess.language.languageCode && $0.region == guess.region && guess.region != nil }
            ?? supported.first { $0.language.languageCode == guess.language.languageCode && $0.region == Locale.current.region }
            ?? supported.first { $0.language.languageCode == guess.language.languageCode && $0.region == likely }
            ?? supported.first { $0.language.languageCode == guess.language.languageCode }
    }

    /// A good first guess for the spoken language: the site's own metadata, then the language of
    /// the title, then the Mac's own language.
    static func guessLanguage(title: String, metadata: String?) -> Locale {
        if let metadata, !metadata.isEmpty { return Locale(identifier: metadata) }
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(title)
        if let guess = recognizer.languageHypotheses(withMaximum: 1).first, guess.value > 0.6 {
            return Locale(identifier: guess.key.rawValue)
        }
        return Locale.current
    }
}

// MARK: - Speech

@available(macOS 26, *)
enum OnDeviceSpeech {
    /// Languages the local recognizer handles, named in the user's language.
    static func languages() async -> [Locale] {
        await SpeechTranscriber.supportedLocales
            .sorted { ($0.localizedString(forIdentifier: $0.identifier) ?? "") < ($1.localizedString(forIdentifier: $1.identifier) ?? "") }
    }

    /// Transcribes 16 kHz mono audio (see `extractAudio`) into timed words. Downloads the
    /// language's speech model first if this Mac doesn't have it yet.
    static func transcribe(_ audio: URL, locale: Locale, duration: Double?,
                           status: @escaping @Sendable (String, Double?) -> Void) async throws -> [Transcript.Word] {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else { throw LocalAI.Failure.unsupportedLanguage }
        let transcriber = SpeechTranscriber(locale: supported, transcriptionOptions: [], reportingOptions: [],
                                            attributeOptions: [.audioTimeRange])
        if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
            status(String(localized: "Downloading speech model…"), nil)
            let progress = request.progress
            let watcher = Task {
                while !Task.isCancelled {
                    status(String(localized: "Downloading speech model…"), progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(300))
                }
            }
            defer { watcher.cancel() }
            try await request.downloadAndInstall()
        }
        status(String(localized: "Transcribing…"), 0)

        let file = try AVAudioFile(forReading: audio)
        let total = duration ?? Double(file.length) / file.fileFormat.sampleRate
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        let collector = Task { () -> [Transcript.Word] in
            var words: [Transcript.Word] = []
            for try await result in transcriber.results {
                for run in result.text.runs {
                    guard let range = run.audioTimeRange else { continue }
                    let text = String(result.text[run.range].characters)
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                    words.append(Transcript.Word(s: range.start.seconds, e: range.end.seconds, t: text))
                }
                if total > 0 { status(String(localized: "Transcribing…"), min(result.range.end.seconds / total, 1)) }
            }
            return words
        }
        do {
            if let end = try await analyzer.analyzeSequence(from: file) {
                try await analyzer.finalizeAndFinish(through: end)
            } else {
                await analyzer.cancelAndFinishNow()
            }
        } catch {
            collector.cancel()
            throw error
        }
        let words = try await collector.value
        guard !words.isEmpty else { throw LocalAI.Failure.noSpeech }
        // Words arrive per result; keep them in time order and make sure the first has no lead space.
        return words.sorted { $0.s < $1.s }
    }
}

// MARK: - Translation

@available(macOS 26, *)
enum OnDeviceTranslation {
    /// Translates subtitle lines, keeping their timing. The language pair must be installed
    /// (the subtitle sheet asks macOS to download it first).
    static func translate(_ cues: [Transcript.Cue], from source: Locale, to target: Locale.Language) async throws -> [Transcript.Cue] {
        let session = TranslationSession(installedSource: source.language, target: target)
        let requests = cues.enumerated().map { TranslationSession.Request(sourceText: $0.element.text, clientIdentifier: String($0.offset)) }
        let responses = try await session.translations(from: requests)
        var translated = cues
        for response in responses {
            guard let id = response.clientIdentifier, let index = Int(id), translated.indices.contains(index) else { continue }
            translated[index].text = response.targetText
        }
        return translated
    }

    static func isInstalled(from source: Locale, to target: Locale.Language) async -> Bool {
        await LanguageAvailability().status(from: source.language, to: target) == .installed
    }
}
