import SwiftUI

/// Remove Silences & Fillers: how tight to cut, whether filler words go too, and whether to save
/// an edit list for a video editor.
struct TightenSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let items: [DownloadItem]
    private var item: DownloadItem { items[0] }
    @AppStorage("tightenPace") private var pace: Tighten.Pace = .natural
    @AppStorage("tightenFillers") private var fillers = true
    @AppStorage("tightenEditList") private var editList = false
    @State private var languages: [Locale] = []
    @State private var language: Locale?

    private var isVideo: Bool { items.contains { $0.existingFile.map(Converting.isVideo) ?? false } }
    private var removesFillers: Bool { fillers && LocalAI.canTranscribe }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "scissors", title: Text("Remove Silences & Fillers"), subtitle: Text(AIStudio.Batch(items).title))

            Form {
                Picker(selection: $pace) {
                    ForEach(Tighten.Pace.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Pace")
                    Text(pace.detail)
                }
                Toggle(isOn: $fillers) {
                    Text("Remove filler words")
                    Text(LocalAI.canTranscribe ? String(localized: "Like “uhm” and “uh”, found in a transcript made on this Mac.")
                                               : String(localized: "Needs macOS 26 or later."))
                }
                .disabled(!LocalAI.canTranscribe)
                if removesFillers {
                    Picker("Spoken language", selection: $language) {
                        if languages.isEmpty { Text("Loading…").tag(Locale?.none) }
                        ForEach(languages, id: \.identifier) { locale in
                            Text(Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier).tag(Optional(locale))
                        }
                    }
                }
                if isVideo {
                    Toggle(isOn: $editList) {
                        Text("Also save an edit list")
                        Text("An EDL with the same cuts, to import into DaVinci Resolve or Premiere Pro.")
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Label("Runs entirely on this Mac with local AI. Pluck saves a tightened copy next to the original; the original isn’t changed.",
                  systemImage: "lock.shield")
                .noteStyle()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Remove") {
                    var options = Tighten.Options()
                    options.pace = pace
                    options.fillers = removesFillers
                    options.language = language
                    options.editList = editList && isVideo
                    for item in items { studio.tighten(item, options: options) }
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(removesFillers && language == nil)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 480)
        .task { await loadLanguages() }
    }

    private func loadLanguages() async {
        guard #available(macOS 26, *), LocalAI.canTranscribe else { return }
        let supported = await OnDeviceSpeech.languages()
        languages = supported
        // The transcript's language if there is one, else a guess from the title.
        let saved = item.transcriptID.flatMap(TranscriptStore.load).map { Locale(identifier: $0.language) }
        let guess = saved ?? LocalAI.guessLanguage(title: item.title, metadata: item.spokenLanguage)
        language = supported.first { $0.identifier == guess.identifier }
            ?? supported.first { $0.language.languageCode == guess.language.languageCode && $0.region == Locale.current.region }
            ?? supported.first { $0.language.languageCode == guess.language.languageCode }
            ?? supported.first { $0.language.languageCode == Locale.current.language.languageCode }
    }
}
