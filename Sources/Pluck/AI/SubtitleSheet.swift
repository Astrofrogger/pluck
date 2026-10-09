import SwiftUI
import Translation

/// Subtitles & Transcript: choose the spoken language, an optional translation, and what to
/// make. Everything runs on this Mac (local AI).
@available(macOS 26, *)
struct SubtitleSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let item: DownloadItem

    @State private var languages: [Locale] = []
    @State private var language: Locale?
    @State private var translationTargets: [Locale.Language] = []
    @State private var translateTo: Locale.Language?
    @AppStorage("subtitlesSaveFile") private var saveFile = true
    @AppStorage("subtitlesEmbed") private var embed = true
    @AppStorage("subtitlesBurnIn") private var burnIn = false
    /// Set to ask macOS to download a translation language pair before starting.
    @State private var translationSetup: TranslationSession.Configuration?

    private var file: URL? { item.existingFile }
    private var isVideo: Bool { file.map(AIStudio.isVideo) ?? false }
    private var canEmbed: Bool { file.map(AIStudio.canEmbedSubtitles) ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "captions.bubble")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subtitles & Transcript").font(.title3.weight(.semibold))
                    Text(item.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            Form {
                Picker("Spoken language", selection: $language) {
                    if languages.isEmpty { Text("Loading…").tag(Locale?.none) }
                    ForEach(languages, id: \.identifier) { locale in
                        Text(name(of: locale)).tag(Optional(locale))
                    }
                }
                Picker("Translate to", selection: $translateTo) {
                    Text("Don’t translate").tag(Locale.Language?.none)
                    ForEach(translationTargets, id: \.minimalIdentifier) { target in
                        Text(Locale.current.localizedString(forIdentifier: target.minimalIdentifier) ?? target.minimalIdentifier)
                            .tag(Optional(target))
                    }
                }
                Toggle("Save a subtitle file (.srt) next to it", isOn: $saveFile)
                if isVideo {
                    Toggle("Add subtitles to the video file", isOn: $embed)
                        .disabled(!canEmbed)
                    Toggle("Burn subtitles into the picture (new copy)", isOn: $burnIn)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Label("Runs entirely on this Mac with local AI: Apple’s on-device speech recognition and translation. Nothing is uploaded.",
                  systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Transcribe", action: start)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(language == nil)
            }
        }
        .padding(24)
        .frame(width: 480)
        .task { await loadLanguages() }
        // macOS asks to download the translation languages if they aren't on this Mac yet.
        .translationTask(translationSetup) { session in
            do {
                try await session.prepareTranslation()
                await MainActor.run { run() }
            } catch {
                await MainActor.run { translationSetup = nil }
            }
        }
    }

    private func name(of locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private func loadLanguages() async {
        let supported = await OnDeviceSpeech.languages()
        languages = supported
        let guess = LocalAI.guessLanguage(title: item.title, metadata: item.spokenLanguage)
        // Same language and region if possible, else the same language anywhere.
        language = supported.first { $0.identifier == guess.identifier }
            ?? supported.first { $0.language.languageCode == guess.language.languageCode && $0.region == Locale.current.region }
            ?? supported.first { $0.language.languageCode == guess.language.languageCode }
            ?? supported.first { $0.language.languageCode == Locale.current.language.languageCode }
        let targets = await LanguageAvailability().supportedLanguages
        translationTargets = targets.sorted {
            (Locale.current.localizedString(forIdentifier: $0.minimalIdentifier) ?? "") < (Locale.current.localizedString(forIdentifier: $1.minimalIdentifier) ?? "")
        }
    }

    private func start() {
        guard let language else { return }
        if let target = translateTo, target.languageCode != language.language.languageCode {
            Task {
                if await OnDeviceTranslation.isInstalled(from: language, to: target) {
                    run()
                } else {
                    translationSetup = TranslationSession.Configuration(source: language.language, target: target)
                }
            }
        } else {
            run()
        }
    }

    private func run() {
        guard let language else { return }
        var request = AIStudio.SubtitleRequest(language: language)
        request.translateTo = translateTo
        request.saveFile = saveFile
        request.embed = embed && canEmbed && isVideo
        request.burnIn = burnIn && isVideo
        studio.makeSubtitles(for: item, request)
        dismiss()
    }
}
