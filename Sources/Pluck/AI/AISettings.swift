import SwiftUI

/// Settings → AI: automatic transcripts for search, and what local AI can do on this Mac.
struct AISettings: View {
    @Environment(AIStudio.self) private var studio
    @Environment(DownloadManager.self) private var manager
    @AppStorage(Prefs.aiAutoTranscribe) private var autoTranscribe = false
    @AppStorage(Prefs.visionModelEnabled) private var visionModelEnabled = true
    @State private var visionProgress: Double?
    @State private var visionError: String?
    @AppStorage(Prefs.visionModel) private var pickedModel = ""
    /// Bumped after a download or removal, so the rows show what's on disk.
    @State private var visionRefresh = 0

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
                status("Shot descriptions", available: VisionModel.best != nil,
                       detail: VisionModel.unavailableReason ?? String(localized: "An open vision model describes every shot for Find Shots and Derush Footage, with an editor’s eye. Sharper than Apple Intelligence."))
                if let model = VisionModel.selected {
                    let _ = visionRefresh
                    // Only the models this Mac has the memory for.
                    Picker(selection: $pickedModel) {
                        ForEach(VisionModel.choices.filter(VisionModel.fits)) { choice in
                            Text(verbatim: choice.name + " · " + Format.bytes(choice.size)
                                 + (VisionModel.isInstalled(choice) ? " ✓" : ""))
                                .tag(choice.repository)
                        }
                    } label: {
                        Text("Model")
                        Text(VisionModel.detail(model))
                    }
                    .disabled(visionProgress != nil)
                    LabeledContent {
                        if let visionProgress {
                            HStack {
                                ProgressView(value: visionProgress).frame(width: 120)
                                Text(visionProgress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit().foregroundStyle(.secondary)
                            }
                        } else if VisionModel.isInstalled(model) {
                            HStack {
                                Toggle("Use", isOn: $visionModelEnabled).labelsHidden()
                                Button("Remove") { remove(model) }
                            }
                        } else {
                            Button("Download") { download(model) }
                        }
                    } label: {
                        Text(verbatim: model.name)
                        if !VisionModel.isInstalled(model), visionProgress == nil {
                            Text("Downloads \(Format.bytes(model.size)) once")
                        }
                    }
                    if let visionError { Text(visionError).foregroundStyle(.red).font(.callout) }
                    // Models downloaded earlier and no longer picked take space: they can go.
                    ForEach(VisionModel.choices.filter { $0 != model && VisionModel.isInstalled($0) }) { other in
                        LabeledContent {
                            Button("Remove") { remove(other) }
                        } label: {
                            Text(verbatim: other.name)
                            Text("Also downloaded (\(Format.bytes(other.size)))")
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            // The picker shows the model in use, also before one was ever picked.
            if let selected = VisionModel.selected, pickedModel != selected.repository { pickedModel = selected.repository }
        }
        .onChange(of: pickedModel) { visionError = nil }

        Label("Pluck’s AI runs locally on this Mac: Apple’s on-device speech recognition, translation and Apple Intelligence, plus open-source models for stems and shot descriptions. Nothing you download, say or search is uploaded.",
              systemImage: "lock.shield")
            .noteStyle()
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
    }

    private func download(_ model: VisionModel.Choice) {
        visionError = nil
        visionProgress = 0
        Task {
            do {
                try await VisionModel.install(model) { value in Task { @MainActor in visionProgress = value } }
            } catch {
                visionError = error.localizedDescription
            }
            visionProgress = nil
            visionRefresh += 1
        }
    }

    private func remove(_ model: VisionModel.Choice) {
        Task { await VisionRunner.shared.stop() }
        VisionModel.remove(model)
        visionRefresh += 1
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
