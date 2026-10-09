import SwiftUI

/// Make Shorts: how many vertical clips, how long, and how they're captioned.
struct ShortsSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let item: DownloadItem
    @AppStorage("shortsCount") private var count = 3
    @AppStorage("shortsLength") private var length: Shorts.Length = .medium
    @AppStorage("shortsCaptionsOn") private var captionsOn = true
    @State private var design = CaptionDesign.load(CaptionDesign.shortsKey)
    @AppStorage("shortsFraming") private var framing: Shorts.FramingChoice = .automatic
    @State private var languages: [Locale] = []
    @State private var language: Locale?

    /// Shorts need a transcript; without one yet, ask which language is spoken.
    private var needsLanguage: Bool {
        LocalAI.canTranscribe && item.transcriptID.flatMap(TranscriptStore.load)?.filePath != item.existingFile?.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "rectangle.portrait.on.rectangle.portrait.angled")
                    .font(.largeTitle)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Make Shorts").font(.title3.weight(.semibold))
                    Text(item.title).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }

            Form {
                if needsLanguage {
                    SpokenLanguagePicker(item: item, languages: $languages, language: $language)
                }
                Stepper(value: $count, in: 1...5) {
                    LabeledContent("Number of shorts") { Text("\(count)").monospacedDigit() }
                }
                Picker("Length", selection: $length) {
                    ForEach(Shorts.Length.allCases) { Text($0.label).tag($0) }
                }
                Picker(selection: $framing) {
                    ForEach(Shorts.FramingChoice.allCases) { Text($0.label).tag($0) }
                } label: {
                    Text("Framing")
                    Text(framing.detail)
                }
                Section {
                    Toggle("Captions", isOn: $captionsOn)
                    if captionsOn {
                        CaptionDesignEditor(design: $design, forShorts: true)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .fixedSize(horizontal: false, vertical: true)

            Label(LocalAI.canSummarize
                  ? "Local AI on this Mac picks the best moments from what’s said, keeps the subject in frame and captions every word. Nothing is uploaded."
                  : "Pluck picks the busiest moments, keeps the subject in frame and captions every word, all on this Mac. With Apple Intelligence on, local AI picks moments by what’s said.",
                  systemImage: "lock.shield")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Make Shorts") {
                    studio.makeShorts(item, options: Shorts.Options(count: count, length: length, captions: captionsOn ? design : nil,
                                                                     framing: framing, language: needsLanguage ? language : nil))
                    design.save(CaptionDesign.shortsKey)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 460)
    }
}
