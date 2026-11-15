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
        VStack(alignment: .leading, spacing: Design.Studio.sectionGap) {
            // Only what this Mac can run: features that need a newer macOS or Apple silicon
            // aren't listed at all.
            if LocalAI.canTranscribe {
                SettingsCard("Transcripts & search") {
                    SettingSwitch("Transcribe new videos automatically",
                                  help: String(localized: "Downloads and videos you open or import, so Search finds what’s said in them. Runs in the background, on this Mac."),
                                  isOn: $autoTranscribe)
                    let missing = studio.needsTranscript(manager.items).count
                    SettingRow("Not transcribed yet") {
                        HStack(spacing: 8) {
                            Text("\(missing)").monospacedDigit().font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                            Button("Transcribe Now") { studio.transcribeInBackground(manager.items) }
                                .settingButton()
                                .disabled(missing == 0)
                        }
                    }
                }
            }
            SettingsCard("Search & photos", info: String(localized: "Add folders in the Library. Advanced film settings and the denoise engine are downloaded from the Photo page when you ask for them. Normal film works without them.")) {
                SettingRow("Library folders") {
                    Text(verbatim: "\(FootageFolders.shared.folders.count)").monospacedDigit().font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                }
                SettingSwitch("Look at new downloads", help: String(localized: "So searches find what’s in their pictures"),
                              isOn: Binding(get: { UserDefaults.standard.object(forKey: VisualIndexer.autoKey) as? Bool ?? true },
                                            set: { UserDefaults.standard.set($0, forKey: VisualIndexer.autoKey) }))
                SettingRow("Film data (advanced settings)") {
                    HStack(spacing: 8) {
                        switch FilmEngine.shared.state {
                        case .ready:
                            Text("Installed").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                            Button("Remove", role: .destructive) { FilmEngine.shared.uninstall() }.settingButton()
                        case .installing:
                            StudioProgress(share: FilmEngine.shared.progress).frame(width: 100)
                        default:
                            Text("Not installed").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                        }
                    }
                }
            }

            SettingsCard("On this Mac") {
                if LocalAI.canTranscribe {
                    status("Transcripts, subtitles & translation", available: true, detail: nil)
                    status("Search inside downloads", available: true,
                           detail: LocalAI.canSummarize ? nil : String(localized: "Works with keywords; Apple Intelligence makes it understand questions."))
                }
                if LocalAI.summariesPossible {
                    status("Summaries & chapters", available: LocalAI.canSummarize, detail: LocalAI.summarizeUnavailableReason)
                }
                if LocalAI.canTranscribe {
                    status("Shorts", available: true,
                           detail: LocalAI.canSummarize ? nil : String(localized: "Picks moments by sound; Apple Intelligence picks them by what’s said."))
                }
                status("Silences, backgrounds, privacy blur & deliverables", available: true, detail: nil)
                if AudioCleanup.isSupported {
                    status("Audio clean-up", available: true, detail: nil)
                }
                if Enhance.isSupported {
                    status("Upscaling & smooth motion", available: true, detail: nil)
                }
                if Stems.isSupported {
                    status("Stems & karaoke", available: true, detail: nil)
                    SettingRow("Stem model") {
                        if Stems.isModelInstalled {
                            HStack(spacing: 8) {
                                Text("Downloaded (\(Format.bytes(Stems.modelSize)))").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                                Button("Remove") { Stems.removeModel() }.settingButton()
                            }
                        } else {
                            Text("Downloads \(Format.bytes(Stems.modelSize)) the first time").font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                        }
                    }
                }
                if VisionModel.best != nil {
                    status("Shot descriptions", available: true,
                           detail: String(localized: "An open vision model describes every shot for Search and Derush Footage, with an editor’s eye. Sharper than Apple Intelligence."))
                }
                if let model = VisionModel.selected {
                    let _ = visionRefresh
                    SettingRow("Model", help: VisionModel.detail(model)) {
                        // Only the models this Mac has the memory for.
                        SettingMenu(title: model.name, selection: $pickedModel) {
                            ForEach(VisionModel.choices.filter(VisionModel.fits)) { choice in
                                Text(verbatim: choice.name + " · " + Format.bytes(choice.size)
                                     + (VisionModel.isInstalled(choice) ? " ✓" : ""))
                                    .tag(choice.repository)
                            }
                        }
                    }
                    .disabled(visionProgress != nil)
                    SettingRow(text: Text(verbatim: model.name),
                               detail: !VisionModel.isInstalled(model) && visionProgress == nil ? Text("Downloads \(Format.bytes(model.size)) once") : nil) {
                        if let visionProgress {
                            HStack(spacing: 8) {
                                StudioProgress(share: visionProgress).frame(width: 120)
                                Text(visionProgress.formatted(.percent.precision(.fractionLength(0)))).monospacedDigit()
                                    .font(Design.Studio.body).foregroundStyle(Design.Studio.textQuiet)
                            }
                        } else if VisionModel.isInstalled(model) {
                            HStack(spacing: 8) {
                                Toggle("Use", isOn: $visionModelEnabled).toggleStyle(StudioSwitchStyle())
                                Button("Remove") { remove(model) }.settingButton()
                            }
                        } else {
                            Button("Download") { download(model) }.settingButton()
                        }
                    }
                    if let visionError { SettingNote(text: Text(visionError), colour: Design.Studio.bad) }
                    // Models downloaded earlier and no longer picked take space: they can go.
                    ForEach(VisionModel.choices.filter { $0 != model && VisionModel.isInstalled($0) }) { other in
                        SettingRow(text: Text(verbatim: other.name), detail: Text("Also downloaded (\(Format.bytes(other.size)))")) {
                            Button("Remove") { remove(other) }.settingButton()
                        }
                    }
                }
            }

            StudioFootnote(text: "Pluck’s AI runs locally on this Mac: Apple’s on-device speech recognition, translation and Apple Intelligence, plus open-source models for stems and shot descriptions. Nothing you download, say or search is uploaded.")
                .multilineTextAlignment(.center)
        }
        .onAppear {
            // The picker shows the model in use, also before one was ever picked.
            if let selected = VisionModel.selected, pickedModel != selected.repository { pickedModel = selected.repository }
        }
        .onChange(of: pickedModel) { visionError = nil }
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
        // What's there is explained on hover; why something isn't stays in view.
        SettingRow(title, help: available ? detail : nil, detail: available ? nil : detail.map { Text($0) }) {
            Image(systemName: available ? "checkmark.circle.fill" : "minus.circle")
                .foregroundStyle(available ? Design.Studio.good : Design.Studio.textFaint)
                .accessibilityLabel(available ? "Available" : "Not available")
        }
    }
}
