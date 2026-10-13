import SwiftUI

/// The inspector next to a project: the selected clip (or music), the story across all its
/// clips, the titles, and the export.
struct ProjectInspector: View {
    @Bindable var model: ProjectModel
    @Binding var tab: Tab

    enum Tab: String, CaseIterable, Identifiable {
        case clip, story, subtitles, titles, export
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .clip: "slider.horizontal.3"
            case .story: "text.book.closed"
            case .subtitles: "captions.bubble"
            case .titles: "textformat"
            case .export: "square.and.arrow.up"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .clip: "Clip"
            case .story: "Story"
            case .subtitles: "Subtitles"
            case .titles: "Titles"
            case .export: "Export"
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 2) {
                ForEach(Tab.allCases) { item in
                    Button { tab = item } label: {
                        Image(systemName: item.symbol)
                            .font(.system(size: 14, weight: .medium))
                            .frame(maxWidth: .infinity, minHeight: 28)
                            .foregroundStyle(tab == item ? Color.accentColor : .secondary)
                            .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(tab == item ? Color.accentColor.opacity(0.14) : .clear))
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .help(Text(item.title))
                }
            }
            .padding(6)
            Divider()
            Text(tab.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            Group {
                switch tab {
                case .clip: ProjectClipPanel(model: model)
                case .story: ProjectStoryPanel(model: model)
                case .subtitles: ProjectSubtitlesPanel(model: model)
                case .titles: ProjectTitlesPanel(model: model)
                case .export: ProjectExportPanel(model: model)
                }
            }
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .background(.background.secondary)
    }
}

/// A name on the left, its controls on the right.
private func inspectorRow<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
    HStack(spacing: 8) {
        Text(title).foregroundStyle(.secondary).lineLimit(1).frame(width: 70, alignment: .leading)
        HStack(spacing: 6) { content() }.frame(maxWidth: .infinity, alignment: .trailing)
    }
    .font(.callout)
    .controlSize(.small)
    .padding(.horizontal, 8)
    .frame(minHeight: 28)
}

// MARK: - Clip

private struct ProjectClipPanel: View {
    @Bindable var model: ProjectModel

    private var clip: ProjectClip? {
        guard model.selected.count == 1, let id = model.selected.first else { return nil }
        return model.project.clips.first { $0.id == id }
    }

    private var song: ProjectMusic? {
        guard model.selected.count == 1, let id = model.selected.first else { return nil }
        return model.project.music.first { $0.id == id }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if let clip {
                    clipSettings(clip)
                } else if let song {
                    musicSettings(song)
                } else {
                    Text(model.selected.count > 1 ? "^[\(model.selected.count) clip](inflect: true) selected" : "Select a clip on the timeline.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    private func clipSettings(_ clip: ProjectClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(clip.name).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(verbatim: "\(clip.file.lastPathComponent) · \(Format.duration(clip.length))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Menu {
                    Button("Duplicate") { model.duplicate([clip.id]) }
                    Button("Open File") { StudioNavigator.shared.open(EditorTarget(path: clip.path), at: clip.start) }
                    Divider()
                    Button("Delete", role: .destructive) { model.delete([clip.id]) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            ClipLookEditor(look: clip.look ?? ClipLook(), path: clip.path) { record, body in
                model.set(clip.id, record: record) { clip in
                    var look = clip.look ?? ClipLook()
                    body(&look)
                    clip.look = look.isDefault ? nil : look
                }
            }
            FoldSection(title: "Audio", key: "clip-audio") {
                inspectorRow("Volume") {
                    Slider(value: Binding(get: { clip.volume }, set: { value in model.set(clip.id, record: false) { $0.volume = value } }), in: 0...2) { editing in
                        if !editing { model.set(clip.id) { _ in } }
                    }
                    Text(verbatim: "\(Int(clip.volume * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                }
                inspectorRow("Fade In") {
                    Slider(value: Binding(get: { clip.fadeIn }, set: { value in model.set(clip.id, record: false) { $0.fadeIn = value } }), in: 0...3)
                    Text(String(format: "%.1f s", clip.fadeIn)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                }
                inspectorRow("Fade Out") {
                    Slider(value: Binding(get: { clip.fadeOut }, set: { value in model.set(clip.id, record: false) { $0.fadeOut = value } }), in: 0...3)
                    Text(String(format: "%.1f s", clip.fadeOut)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
                }
            }
        }
    }

    private func musicSettings(_ song: ProjectMusic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(song.name, systemImage: "music.note").font(.callout.weight(.semibold)).lineLimit(2).padding(.horizontal, 8).padding(.bottom, 6)
            inspectorRow("Starts at") { Text(Format.duration(song.at)).monospacedDigit() }
            inspectorRow("Volume") {
                Slider(value: Binding(get: { song.volume }, set: { value in model.setMusic(song.id, record: false) { $0.volume = value } }), in: 0...1.5)
                Text(verbatim: "\(Int(song.volume * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(width: 38, alignment: .trailing)
            }
            inspectorRow("Fade In") {
                Slider(value: Binding(get: { song.fadeIn }, set: { value in model.setMusic(song.id, record: false) { $0.fadeIn = value } }), in: 0...6)
            }
            inspectorRow("Fade Out") {
                Slider(value: Binding(get: { song.fadeOut }, set: { value in model.setMusic(song.id, record: false) { $0.fadeOut = value } }), in: 0...8)
            }
            HStack {
                Button("Fit to the Edit") {
                    model.setMusic(song.id) { $0.at = 0; $0.end = min($0.start + model.duration, $0.end + model.duration) }
                }
                .help("Start with the first clip and run to the end")
                Spacer()
                Button("Remove", role: .destructive) { model.removeMusic(song.id) }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
    }
}

// MARK: - Story

/// The story across every clip's file: local AI reads all the transcripts together and lays
/// the strongest passages out in story order, ready to rearrange on the timeline.
private struct ProjectStoryPanel: View {
    @Bindable var model: ProjectModel
    @Environment(AIStudio.self) private var ai
    @Environment(DownloadManager.self) private var manager
    @AppStorage("storyFocus") private var focus = ""
    @AppStorage("transcriptLanguage") private var language = ""
    @AppStorage("storyLength") private var length = 0.0
    @State private var transcribed: Set<String> = []

    private var files: [String] { model.project.files }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Local AI reads every file together and lays out the strongest passages as a story. Rearrange them on the timeline after.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                SidebarSection(title: Text("Files")) {
                    ForEach(files, id: \.self) { path in
                        SidebarRow(symbol: transcribed.contains(path) ? "checkmark.circle.fill" : "circle.dashed",
                                   title: Text(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent),
                                   detail: transcribed.contains(path) ? nil : Text("No transcript")) {
                            EmptyView()
                        }
                    }
                }
                let missing = files.filter { !transcribed.contains($0) }
                if !missing.isEmpty, LocalAI.canTranscribe {
                    Button("Transcribe \(missing.count) Files", systemImage: "waveform") {
                        ai.transcribeInBackground(manager.addLocalFiles(missing.map { URL(fileURLWithPath: $0) }))
                    }
                    .buttonStyle(.link)
                    .padding(.horizontal, 8)
                }
                TextField("About (optional): the new building…", text: $focus)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .padding(.horizontal, 8)
                inspectorRow("Length") {
                    Picker("Length", selection: $length) {
                        ForEach(StoryFinder.lengths, id: \.self) { Text(StoryFinder.lengthTitle($0)).tag($0) }
                    }
                    .labelsHidden()
                }
                if model.storyFinding {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Reading the interviews…").font(.caption).foregroundStyle(.secondary)
                        ProgressView(value: model.storyProgress).controlSize(.small)
                    }
                    .padding(.horizontal, 8)
                } else {
                    Button("Lay Out the Story", systemImage: "text.book.closed", action: find)
                        .buttonStyle(BrandButtonStyle())
                        .disabled(transcribed.isEmpty)
                        .padding(.horizontal, 8)
                }
                if let problem = model.storyProblem { Text(problem).font(.caption).foregroundStyle(.orange).padding(.horizontal, 8) }
                if !model.storyPassages.isEmpty {
                    SidebarSection(title: Text("Story")) {
                        ForEach(model.storyPassages) { passage in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: passage.beat.role.symbol).foregroundStyle(passage.beat.role.color).frame(width: 16)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(passage.beat.title).font(.callout.weight(.medium)).lineLimit(2)
                                    Text(passage.file).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                }
                            }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .task(id: files) {
            refreshTranscribed()
            // Screenshots: -PluckScreenshotStory YES lays the story out straight away.
            if ScreenshotMode.scene == "project", UserDefaults.standard.bool(forKey: "PluckScreenshotStory"), model.storyPassages.isEmpty, !model.storyFinding,
               files.count > 1, !transcribed.isEmpty {
                find()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptStore.didSave)) { _ in refreshTranscribed() }
    }

    private func refreshTranscribed() {
        transcribed = Set(files.filter { TranscriptStore.find(forFile: $0) != nil })
    }

    private func find() {
        let model = model
        model.storyFinding = true
        model.storyProblem = nil
        model.storyProgress = 0
        let paths = files.filter { transcribed.contains($0) }
        let topic = focus, titles = language.isEmpty ? nil : language, length = length
        Task {
            do {
                let found = try await ProjectStory.find(in: paths, focus: topic, titlesIn: titles, length: length) { value in
                    Task { @MainActor in model.storyProgress = value }
                }
                model.storyPassages = found
                model.lay(ProjectStory.clips(found))
            } catch {
                model.storyProblem = error.localizedDescription
            }
            model.storyFinding = false
        }
    }
}

// MARK: - Titles

private struct ProjectTitlesPanel: View {
    @Bindable var model: ProjectModel

    private var style: Binding<SubtitleStyle> {
        Binding(get: { model.project.titleStyle }, set: { model.setTitleStyle($0) })
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Button("Add a Title at the Playhead", systemImage: "plus") { model.addTitle(at: model.time) }
                    .buttonStyle(BrandButtonStyle(large: false))
                    .padding(.horizontal, 8)
                SidebarSection(title: Text("Look")) {
                    inspectorRow("Font") {
                        Picker("Font", selection: style.font) {
                            ForEach(SubtitleStyle.fonts, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                    inspectorRow("Weight") {
                        Picker("Weight", selection: style.weight) {
                            ForEach(SubtitleStyle.weights, id: \.value) { Text($0.title).tag($0.value) }
                        }
                        .labelsHidden()
                    }
                    inspectorRow("Size") { Slider(value: style.scale, in: 0.6...4) }
                    inspectorRow("Colour") {
                        ColorPicker("Colour", selection: Binding(get: { SubtitleStyle.color(model.project.titleStyle.color) },
                                                                  set: { var s = model.project.titleStyle; s.color = SubtitleStyle.hex($0); model.setTitleStyle(s) }),
                                    supportsOpacity: false)
                            .labelsHidden()
                    }
                    inspectorRow("Shadow") { Slider(value: style.shadow, in: 0...8) }
                    inspectorRow("Place") {
                        Picker("Place", selection: style.y) {
                            Text("Top").tag(0.15)
                            Text("Middle").tag(0.5)
                            Text("Bottom").tag(0.85)
                        }
                        .pickerStyle(.segmented)
                        .labelsHidden()
                    }
                }
                SidebarSection(title: Text("Titles")) {
                    ForEach(model.project.titles.sorted { $0.start < $1.start }) { title in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(Format.duration(title.start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
                                Spacer()
                                Button { model.removeTitle(title.id) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.plain).foregroundStyle(.secondary)
                            }
                            TextField("Title", text: Binding(get: { title.text }, set: { value in model.setTitle(title.id, record: false) { $0.text = value } }),
                                      axis: .vertical)
                                .textFieldStyle(.roundedBorder)
                                .lineLimit(1...3)
                        }
                        .padding(8)
                        .background(RoundedRectangle(cornerRadius: Design.Radius.small)
                            .fill(model.selectedTitle == title.id ? Design.Brand.violet.opacity(0.18) : Color.primary.opacity(0.04)))
                        .onTapGesture { model.selectedTitle = title.id; model.seek(to: title.start + 0.01) }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Export

private struct ProjectExportPanel: View {
    @Bindable var model: ProjectModel
    @Environment(DownloadManager.self) private var manager
    @AppStorage("projectExportAudio") private var audioOnly = false
    @AppStorage("editorRenderSettings") private var stored = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Picker("Format", selection: $audioOnly) {
                    Label("Video", systemImage: "film").tag(false)
                    Label("Audio", systemImage: "waveform").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                RenderSettingsForm(audioOnly: audioOnly)
                VStack(alignment: .leading, spacing: 8) {
                    let settings = EditorRenderSettings(saved: stored)
                    let size = settings.outputSize(source: model.renderSize)
                    Text(verbatim: "\(model.timecode(model.duration)) · \(Int(size.width))×\(Int(size.height)) · ≈ "
                         + ByteCountFormatter.string(fromByteCount: settings.estimatedBytes(source: model.renderSize, sourceFPS: model.frameRate,
                                                                                             length: model.duration), countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        model.exports.run(model.project, settings: settings, audioOnly: audioOnly, size: model.renderSize,
                                          fps: model.frameRate, manager: manager)
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(model.project.clips.isEmpty || model.exports.isRunning)
                    if let progress = model.exports.progress {
                        ProgressView(value: progress).controlSize(.small)
                    } else if let problem = model.exports.problem {
                        Text(problem).font(.caption).foregroundStyle(.orange)
                    }
                }
                .padding(.horizontal, 8)
                if !model.exports.finished.isEmpty {
                    SidebarSection(title: Text("Exported")) {
                        ForEach(model.exports.finished, id: \.self) { file in
                            DoneLabel(text: Text(file.lastPathComponent), file: file).font(.caption).padding(.horizontal, 8)
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }
}

// MARK: - Subtitles

/// The project's subtitles: made from each clip's transcript, so they move with the clips.
/// Change a line's words or take it out; the look; burned into the export (and saved as .srt).
private struct ProjectSubtitlesPanel: View {
    @Bindable var model: ProjectModel
    @Environment(AIStudio.self) private var ai
    @Environment(DownloadManager.self) private var manager
    @State private var editing: String?
    @State private var draft = ""
    @State private var transcribed: Set<String> = []

    private var style: Binding<SubtitleStyle> {
        Binding(get: { model.project.subtitleLook }, set: { model.setSubtitleStyle($0) })
    }

    private var files: [String] {
        var seen: Set<String> = []
        return model.project.clips.map(\.path).filter { seen.insert($0).inserted }
    }

    /// Languages the transcripts were translated into.
    private var languages: [String] {
        Array(Set(files.compactMap { TranscriptStore.find(forFile: $0)?.translations?.keys }.flatMap { $0 })).sorted()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                let lines = model.subtitles
                let missing = files.filter { !transcribed.contains($0) }
                HStack {
                    Toggle("Show and burn in", isOn: Binding(get: { model.project.subtitlesOn == true }, set: { model.setSubtitles(on: $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    Spacer()
                    Button("Export…", systemImage: "square.and.arrow.down") {
                        SubtitleSaver.save(model.project.subtitleCues, name: model.project.name)
                    }
                    .controlSize(.small)
                    .disabled(lines.isEmpty)
                    .help("The subtitles on their own, as .srt or .vtt")
                }
                .padding(.horizontal, 8)
                if !missing.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("^[\(missing.count) file](inflect: true) without a transcript: no subtitles there yet.")
                            .font(.caption).foregroundStyle(.secondary)
                        if LocalAI.canTranscribe {
                            Button("Transcribe Them", systemImage: "waveform") {
                                ai.transcribeInBackground(manager.addLocalFiles(missing.map { URL(fileURLWithPath: $0) }))
                            }
                            .buttonStyle(.link)
                        }
                    }
                    .padding(.horizontal, 8)
                }
                if !languages.isEmpty {
                    inspectorRow("Language") {
                        Picker("Language", selection: Binding(get: { model.project.subtitleLanguage ?? "" }, set: { model.setSubtitleLanguage($0) })) {
                            Text("As Spoken").tag("")
                            ForEach(languages, id: \.self) { code in
                                Text(Locale.current.localizedString(forLanguageCode: code) ?? code).tag(code)
                            }
                        }
                        .labelsHidden()
                    }
                }
                SidebarSection(title: Text("Look")) {
                    SubtitleStyleEditor(style: style)
                }
                if !lines.isEmpty {
                    SidebarSection(title: Text("Lines")) {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(lines) { line in row(line) }
                        }
                    }
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
        .task(id: files) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptStore.didSave)) { _ in refresh(); model.transcriptsChanged() }
    }

    private func refresh() {
        transcribed = Set(files.filter { TranscriptStore.find(forFile: $0) != nil })
    }

    private func row(_ line: ProjectSubtitle) -> some View {
        let playing = line.start <= model.time && model.time < line.end
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Format.duration(line.start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 34, alignment: .leading)
            if editing == line.key {
                TextField("Line", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.callout)
                    .onSubmit { commit(line) }
                    .onExitCommand { editing = nil }
            } else {
                Text(line.text).font(.callout).foregroundStyle(playing ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                    .onTapGesture(count: 2) { draft = line.text; editing = line.key }
                    .onTapGesture { model.seek(to: line.start) }
            }
            Menu {
                Button("Change…") { draft = line.text; editing = line.key }
                if line.edited { Button("As Transcribed") { model.editSubtitle(line.key, text: nil) } }
                Button("Take Out", role: .destructive) { model.editSubtitle(line.key, text: "") }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(playing ? Color.accentColor.opacity(0.12) : .clear))
    }

    private func commit(_ line: ProjectSubtitle) {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        if text != line.text { model.editSubtitle(line.key, text: text.isEmpty ? "" : text) }
        editing = nil
    }
}
