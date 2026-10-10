import SwiftUI
import Translation

/// Make Deliverables: which formats, what loudness, which subtitle languages, and how the
/// files are named.
struct DeliverablesSheet: View {
    @Environment(AIStudio.self) private var studio
    @Environment(\.dismiss) private var dismiss
    let item: DownloadItem
    @AppStorage("deliverablesFormats") private var formatList = "landscape,vertical"
    @AppStorage("deliverablesLoudness") private var loudness: Deliverables.Loudness = .online
    @AppStorage("deliverablesSubtitles") private var subtitles = true
    /// "off", "" for the spoken language, or a translation's identifier.
    @AppStorage("deliverablesBurnIn") private var burnIn = ""
    @AppStorage("deliverablesTemplate") private var template = "{client}_{project}_{format}_{version}"
    @AppStorage("deliverablesClient") private var client = ""
    @State private var project = ""
    @State private var version = 1
    @State private var translateTo = TranslationTargetsMenu.load("deliverablesTranslateTo")
    @State private var translationTargets: [Locale.Language] = []
    @State private var languages: [Locale] = []
    @State private var language: Locale?

    private var formats: [Deliverables.Format] {
        let chosen = Set(formatList.split(separator: ",").map(String.init))
        return Deliverables.Format.allCases.filter { chosen.contains($0.rawValue) }
    }

    private var naming: Deliverables.Naming {
        Deliverables.Naming(template: template, client: client, project: project, version: version)
    }

    private var burnsIn: Bool { burnIn != "off" && formats.contains(where: \.isSocial) }

    private var needsLanguage: Bool {
        (subtitles || burnsIn) && LocalAI.canTranscribe && item.transcriptID.flatMap(TranscriptStore.load)?.filePath != item.existingFile?.path
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Spacing.section) {
            SheetHeader(symbol: "square.stack.3d.down.right", title: Text("Make Deliverables"), subtitle: Text(item.title))

            Form {
                Section {
                    ForEach(Deliverables.Format.allCases) { format in
                        Toggle(format.label, isOn: binding(for: format))
                    }
                } header: {
                    Text("Formats")
                } footer: {
                    Text("Each shot is framed on its people or subject; titles are shown whole.").foregroundStyle(.secondary)
                }
                Section("Sound") {
                    Picker("Loudness", selection: $loudness) {
                        ForEach(Deliverables.Loudness.allCases) { Text($0.label).tag($0) }
                    }
                }
                if LocalAI.canTranscribe {
                    Section {
                        Toggle("Subtitle files (.srt)", isOn: $subtitles)
                        if formats.contains(where: \.isSocial) {
                            Picker("In the picture", selection: $burnIn) {
                                Text("No subtitles").tag("off")
                                Text("Spoken language").tag("")
                                ForEach(translateTo, id: \.minimalIdentifier) { Text(TranslationTargetsMenu.name(of: $0)).tag($0.minimalIdentifier) }
                            }
                        }
                        if subtitles || burnsIn {
                            if needsLanguage {
                                SpokenLanguagePicker(item: item, languages: $languages, language: $language)
                            }
                            TranslationTargetsMenu(title: "Also in", selection: $translateTo, languages: translationTargets,
                                                   source: language?.language)
                        }
                    } header: {
                        Text("Subtitles")
                    } footer: {
                        if formats.contains(where: \.isSocial) {
                            Text("Burned into 9:16, 1:1 and 4:5 only, in your subtitle style, clear of the apps’ buttons.").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    TextField("Client", text: $client)
                    TextField("Project", text: $project)
                    Stepper(value: $version, in: 1...99) {
                        LabeledContent("Version") { Text(String(format: "v%02d", version)).monospacedDigit() }
                    }
                    TextField("File names", text: $template)
                } header: {
                    Text("Names")
                } footer: {
                    Text("For example: \(naming.name(source: item.existingFile?.deletingPathExtension().lastPathComponent ?? item.title, format: (formats.first ?? .landscape).tag, language: nil)).mp4. Use \(Deliverables.Naming.tokens.joined(separator: " ")).")
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
            .formStyle(.grouped)
            .frame(minHeight: 420)

            Label("Runs on this Mac: framing, loudness, transcription and translation. Nothing is uploaded.", systemImage: "lock.shield")
                .noteStyle()

            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Make Deliverables") {
                    TranslationTargetsMenu.save(translateTo, "deliverablesTranslateTo")
                    studio.makeDeliverables(item, options: Deliverables.Options(
                        formats: formats, loudness: loudness, subtitles: subtitles && LocalAI.canTranscribe,
                        translations: translateTo, naming: naming, language: needsLanguage ? language : nil,
                        burnIn: burnsIn && LocalAI.canTranscribe ? burnIn : nil))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(formats.isEmpty && !subtitles)
            }
        }
        .padding(Design.Spacing.sheet)
        .frame(width: 520)
        .onChange(of: translateTo.map(\.minimalIdentifier)) { _, chosen in
            if burnIn != "off", !burnIn.isEmpty, !chosen.contains(burnIn) { burnIn = "" }
        }
        .task {
            if #available(macOS 15, *) {
                translationTargets = await LanguageAvailability().supportedLanguages.sorted {
                    TranslationTargetsMenu.name(of: $0) < TranslationTargetsMenu.name(of: $1)
                }
            }
        }
    }

    private func binding(for format: Deliverables.Format) -> Binding<Bool> {
        Binding {
            formats.contains(format)
        } set: { on in
            var chosen = formats.map(\.rawValue)
            if on { chosen.append(format.rawValue) } else { chosen.removeAll { $0 == format.rawValue } }
            formatList = Deliverables.Format.allCases.map(\.rawValue).filter(chosen.contains).joined(separator: ",")
        }
    }
}
