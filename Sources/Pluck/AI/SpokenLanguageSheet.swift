import SwiftUI

/// Asks which language is spoken before Summarize or Add Chapters makes the transcript they need.
struct SpokenLanguageSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let ask: AIStudio.LanguageAsk
    @State private var languages: [Locale] = []
    @State private var language: Locale?

    private var actionTitle: String {
        switch ask.action {
        case .summarize: String(localized: "Summarize")
        case .chapters: String(localized: "Add Chapters")
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: ask.action == .summarize ? "text.badge.star" : "list.number")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(actionTitle).font(.title3.weight(.semibold))
                    Text(ask.item.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            Form {
                SpokenLanguagePicker(item: ask.item, languages: $languages, language: $language)
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Text("Pluck first writes down what’s said, with local AI on this Mac. Choose the language people speak in this file.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(actionTitle) {
                    switch ask.action {
                    case .summarize: studio.summarize(ask.item, language: language, openPlayer: ask.openPlayer)
                    case .chapters: studio.addChapters(ask.item, language: language, openPlayer: ask.openPlayer)
                    }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(language == nil)
            }
        }
        .padding(24)
        .frame(width: 440)
    }
}

/// "Spoken language", filled with the languages this Mac can transcribe and a good first guess
/// (the saved transcript's language, the site's metadata, then the title).
struct SpokenLanguagePicker: View {
    let item: DownloadItem
    @Binding var languages: [Locale]
    @Binding var language: Locale?

    var body: some View {
        Picker("Spoken language", selection: $language) {
            if languages.isEmpty { Text("Loading…").tag(Locale?.none) }
            ForEach(languages, id: \.identifier) { locale in
                Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(Optional(locale))
            }
        }
        .task {
            guard #available(macOS 26, *), LocalAI.canTranscribe, languages.isEmpty else { return }
            let supported = await OnDeviceSpeech.languages()
            languages = supported
            let saved = item.transcriptID.flatMap(TranscriptStore.load).map { Locale(identifier: $0.language) }
            let guess = saved ?? LocalAI.guessLanguage(title: item.title, metadata: item.spokenLanguage)
            language = LocalAI.match(guess, in: supported) ?? LocalAI.match(Locale.current, in: supported)
        }
    }
}
