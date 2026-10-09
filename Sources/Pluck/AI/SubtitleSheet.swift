import SwiftUI
import Translation

/// Subtitles & Transcript: choose the spoken language, an optional translation, and what to
/// make. Everything runs on this Mac (local AI).
@available(macOS 26, *)
struct SubtitleSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let items: [DownloadItem]
    /// Language guesses and the title come from the first item.
    private var item: DownloadItem { items[0] }

    @State private var languages: [Locale] = []
    @State private var language: Locale?
    @State private var translationTargets: [Locale.Language] = []
    @State private var translateTo = TranslationTargetsMenu.load(Self.targetsKey)
    /// The language burned into the picture: "" for the spoken one, else a translation's id.
    @State private var burnInLanguage = ""
    /// Translation languages macOS still has to download, asked for one at a time.
    @State private var pendingSetup: [Locale.Language] = []
    private static let targetsKey = "subtitleTranslateTo"
    @AppStorage("subtitlesSaveFile") private var saveFile = true
    @AppStorage("subtitlesEmbed") private var embed = true
    @AppStorage("subtitlesBurnIn") private var burnIn = false
    @AppStorage("subtitlesLabelSpeakers") private var labelSpeakers = false
    @State private var design = CaptionDesign.load(CaptionDesign.subtitlesKey)
    /// Set to ask macOS to download a translation language pair before starting.
    @State private var translationSetup: TranslationSession.Configuration?

    private func isVideo(_ item: DownloadItem) -> Bool { item.existingFile.map(AIStudio.isVideo) ?? false }
    private func canEmbed(_ item: DownloadItem) -> Bool { item.existingFile.map(AIStudio.canEmbedSubtitles) ?? false }
    private var isVideo: Bool { items.contains(where: isVideo) }
    private var canEmbed: Bool { items.contains(where: canEmbed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "captions.bubble")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Subtitles & Transcript").font(.title3.weight(.semibold))
                    Text(AIStudio.Batch(items).title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            Form {
                Picker("Spoken language", selection: $language) {
                    if languages.isEmpty { Text("Loading…").tag(Locale?.none) }
                    ForEach(languages, id: \.identifier) { locale in
                        Text(name(of: locale)).tag(Optional(locale))
                    }
                }
                TranslationTargetsMenu(title: "Translate to", selection: $translateTo,
                                       languages: translationTargets, source: language?.language)
                if Speakers.isSupported {
                    Toggle(isOn: $labelSpeakers) {
                        Text("Label who’s speaking")
                        Text("Puts the speaker’s name where it changes. Up to four speakers; rename them in Pluck Player.")
                    }
                }
                Toggle("Save a subtitle file (.srt) next to it", isOn: $saveFile)
                if isVideo {
                    Toggle("Add subtitles to the video file", isOn: $embed)
                        .disabled(!canEmbed)
                    Toggle("Burn subtitles into the picture (new copy)", isOn: $burnIn)
                }
                if isVideo, burnIn {
                    Section("Look") {
                        if !targets.isEmpty {
                            Picker("Language in the picture", selection: $burnInLanguage) {
                                Text(language.map(name(of:)) ?? String(localized: "Spoken language")).tag("")
                                ForEach(targets, id: \.minimalIdentifier) { target in
                                    Text(TranslationTargetsMenu.name(of: target)).tag(target.minimalIdentifier)
                                }
                            }
                        }
                        CaptionDesignEditor(design: $design, forShorts: false)
                    }
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
        .onChange(of: translateTo.map(\.minimalIdentifier)) { old, _ in
            // The first translation chosen goes into the picture; a removed one falls back.
            let gone = !burnInLanguage.isEmpty && !targets.contains { $0.minimalIdentifier == burnInLanguage }
            if gone || (burnInLanguage.isEmpty && old.isEmpty) {
                burnInLanguage = targets.first?.minimalIdentifier ?? ""
            }
        }
        // macOS asks to download the translation languages if they aren't on this Mac yet.
        .translationTask(translationSetup) { session in
            do {
                try await session.prepareTranslation()
                await MainActor.run { prepareNext() }
            } catch {
                await MainActor.run {
                    translationSetup = nil
                    pendingSetup = []
                }
            }
        }
    }

    /// The chosen translations, without the spoken language itself.
    private var targets: [Locale.Language] {
        translateTo.filter { $0.languageCode != language?.language.languageCode }
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
        // Keep remembered choices this Mac can still translate into.
        translateTo = translateTo.compactMap { chosen in translationTargets.first { $0.minimalIdentifier == chosen.minimalIdentifier } }
        // A translation goes into the picture by default, as before.
        burnInLanguage = targets.first?.minimalIdentifier ?? ""
    }

    private func start() {
        guard let language else { return }
        let targets = targets
        Task {
            var missing: [Locale.Language] = []
            for target in targets where !(await OnDeviceTranslation.isInstalled(from: language, to: target)) {
                missing.append(target)
            }
            pendingSetup = missing
            if let first = missing.first {
                translationSetup = TranslationSession.Configuration(source: language.language, target: first)
            } else {
                run()
            }
        }
    }

    /// One language is ready: ask for the next missing one, or start once all are there.
    private func prepareNext() {
        guard let language else { return }
        if !pendingSetup.isEmpty { pendingSetup.removeFirst() }
        if let next = pendingSetup.first {
            translationSetup = TranslationSession.Configuration(source: language.language, target: next)
        } else {
            run()
        }
    }

    private func run() {
        guard let language else { return }
        var request = AIStudio.SubtitleRequest(language: language)
        request.translateTo = targets
        request.burnInLanguage = targets.first { $0.minimalIdentifier == burnInLanguage }
        TranslationTargetsMenu.save(translateTo, Self.targetsKey)
        request.saveFile = saveFile
        request.labelSpeakers = labelSpeakers && Speakers.isSupported
        request.design = design
        design.save(CaptionDesign.subtitlesKey)
        // The same choices for every file; embedding and burning in only where the file allows.
        for item in items {
            var own = request
            own.embed = embed && canEmbed(item) && isVideo(item)
            own.burnIn = burnIn && isVideo(item)
            studio.makeSubtitles(for: item, own)
        }
        dismiss()
    }
}
