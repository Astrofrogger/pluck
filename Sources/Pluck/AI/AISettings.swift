import SwiftUI

/// Settings → AI: automatic transcripts for search, and what local AI can do on this Mac.
struct AISettings: View {
    @Environment(AIStudio.self) private var studio
    @Environment(DownloadManager.self) private var manager
    @AppStorage(Prefs.aiAutoTranscribe) private var autoTranscribe = false

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $autoTranscribe) {
                    Text("Transcribe new downloads automatically")
                    Text("So you can search inside them. Runs in the background after each download.")
                }
                .disabled(!LocalAI.canTranscribe)
                let missing = studio.needsTranscript(manager.items).count
                LabeledContent("Not transcribed yet") {
                    HStack {
                        Text("\(missing)").monospacedDigit().foregroundStyle(.secondary)
                        Button("Transcribe Now") { studio.transcribeInBackground(manager.items) }
                            .disabled(missing == 0 || !LocalAI.canTranscribe)
                    }
                }
            } header: {
                Text("Transcripts & search")
            }

            Section("On this Mac") {
                status("Transcripts, subtitles & translation", available: LocalAI.canTranscribe,
                       detail: LocalAI.canTranscribe ? nil : String(localized: "Needs macOS 26 or later."))
                status("Search inside downloads", available: LocalAI.canTranscribe,
                       detail: LocalAI.canSummarize ? nil : String(localized: "Works with keywords; Apple Intelligence makes it understand questions."))
                status("Summaries & chapters", available: LocalAI.canSummarize, detail: LocalAI.summarizeUnavailableReason)
                status("Shorts", available: LocalAI.canTranscribe,
                       detail: LocalAI.canSummarize ? nil : String(localized: "Picks moments by sound; Apple Intelligence picks them by what’s said."))
                status("Stems & karaoke", available: Stems.isSupported, detail: Stems.unavailableReason)
                if Stems.isSupported {
                    LabeledContent("Stem model") {
                        if Stems.isModelInstalled {
                            HStack {
                                Text("Downloaded (\(Format.bytes(Stems.modelSize)))").foregroundStyle(.secondary)
                                Button("Remove") { Stems.removeModel() }
                            }
                        } else {
                            Text("Downloads \(Format.bytes(Stems.modelSize)) the first time").foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        Label("Pluck’s AI runs locally on this Mac: Apple’s on-device speech recognition, translation and Apple Intelligence, plus an open-source stem separation model. Nothing you download, say or search is uploaded.",
              systemImage: "lock.shield")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }

    private func status(_ title: LocalizedStringKey, available: Bool, detail: String?) -> some View {
        LabeledContent {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? .green : .secondary)
                .accessibilityLabel(available ? "Available" : "Not available")
        } label: {
            Text(title)
            if let detail { Text(detail) }
        }
    }
}
