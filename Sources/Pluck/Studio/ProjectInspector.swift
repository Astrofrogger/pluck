import SwiftUI
import UniformTypeIdentifiers

/// The inspector next to a project: the selected clip (or music), the story across all its
/// clips, the titles, and the export.
struct ProjectInspector: View {
    @Bindable var model: ProjectModel
    @Binding var tab: Tab

    enum Tab: String, CaseIterable, Identifiable {
        case clip, colour, audio, text, ai, export
        var id: String { rawValue }

        var symbol: String {
            switch self {
            case .clip: "slider.horizontal.3"
            case .colour: "camera.filters"
            case .audio: "speaker.wave.2"
            case .text: "text.quote"
            case .ai: "sparkles"
            case .export: "square.and.arrow.up"
            }
        }

        var title: LocalizedStringKey {
            switch self {
            case .clip: "Clip"
            case .colour: "Colour"
            case .audio: "Audio"
            case .text: "Text"
            case .ai: "Local AI"
            case .export: "Export"
            }
        }

        /// What's chosen on the timeline, for the inspector to follow.
        enum Chosen { case title, look, clip, nothing }

        /// The tab for what was just chosen: a title's words are in Text, a look's colour in
        /// Colour; a clip keeps the tab open, but Text (its titles aren't about the clip) gives way to Clip.
        static func following(_ current: Tab, _ chosen: Chosen) -> Tab {
            switch chosen {
            case .title: .text
            case .look: .colour
            case .clip: current == .text ? .clip : current
            case .nothing: current
            }
        }

        /// A tab as saved, also by Pluck 3.8.0 (whose Transcript, Subtitles and Titles are in
        /// Text now, Story in Local AI, and Marks on the timeline).
        static func saved(_ raw: String) -> Tab {
            if let tab = Tab(rawValue: raw) { return tab }
            switch raw {
            case "transcript", "subtitles", "titles": return .text
            case "story": return .ai
            default: return .clip
            }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            InspectorTabBar(tabs: Tab.allCases, selection: $tab, symbol: \.symbol) { Text($0.title) }
            Divider()
            Text(tab.title)
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 6)
            Group {
                switch tab {
                case .clip: ProjectClipPanel(model: model, part: .clip)
                case .colour: ProjectClipPanel(model: model, part: .colour)
                case .audio: ProjectClipPanel(model: model, part: .audio)
                case .text: ProjectTextTab(model: model)
                case .ai: ProjectAITab(model: model)
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
        Text(title).foregroundStyle(.secondary).lineLimit(2).fixedSize(horizontal: false, vertical: true).frame(width: Design.Sidebar.sliderLabel, alignment: .leading)
        HStack(spacing: 6) { content() }.frame(maxWidth: .infinity, alignment: .trailing)
    }
    .font(.callout)
    .controlSize(.small)
    .padding(.horizontal, Design.Sidebar.rowPadding)
    .frame(minHeight: Design.Sidebar.sliderHeight)
}

// MARK: - Clip

private struct ProjectClipPanel: View {
    @Bindable var model: ProjectModel
    /// Which tab it fills: the clip's picture and transition, its colour, or its sound.
    var part: Part

    enum Part { case clip, colour, audio }

    private var clip: ProjectClip? {
        guard model.selected.count == 1, let id = model.selected.first else { return nil }
        return model.project.clips.first { $0.id == id }
    }

    private var song: ProjectMusic? {
        guard model.selected.count == 1, let id = model.selected.first else { return nil }
        return model.project.music.first { $0.id == id }
    }

    /// A clip on one of the extra tracks (laid over the picture, or a sound).
    private var item: ProjectClip? {
        guard model.selected.count == 1, let id = model.selected.first else { return nil }
        return (model.project.tracks ?? []).flatMap(\.items).first { $0.id == id }
    }

    /// A look over a part of the timeline.
    private var look: ProjectAdjustment? {
        guard model.selected.count == 1, let id = model.selected.first else { return nil }
        return model.adjustment(id)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                switch part {
                case .clip:
                    if let clip { clipSettings(clip) }
                    else if let song { songHeader(song) }
                    else if let item { itemSettings(item) }
                    else if look != nil { hint("Its colour is in Colour.") }
                    else if model.selected.count > 1 { several }
                    else { overview }
                case .colour:
                    if let clip { colourSettings(look: clip.look, path: clip.path) { record, body in model.set(clip.id, record: record, body) } }
                    else if let look { lookSettings(look) }
                    else if let item, isPicture(item) { colourSettings(look: item.look, path: item.path) { record, body in model.setItem(item.id, record: record, body) } }
                    else { hint("Select a clip or a look on the timeline.") }
                case .audio:
                    if let clip { clipAudio(clip) }
                    else if let song { musicSettings(song) }
                    else if let item { itemAudio(item) }
                    else { hint("Select a clip or a song on the timeline.") }
                }
            }
            .panelColumn()
            .padding(.bottom, 12)
        }
    }

    private var several: some View {
        Text("^[\(model.selected.count) clip](inflect: true) selected")
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 8)
    }

    private func hint(_ text: LocalizedStringKey) -> some View {
        Text(text).font(.callout).foregroundStyle(.secondary).padding(.horizontal, 8)
    }

    private func isPicture(_ item: ProjectClip) -> Bool {
        Converting.isVideo(item.file) && model.project.tracks?.first(where: { $0.items.contains { $0.id == item.id } })?.kind == .video
    }

    /// The colour part of a clip's look, changed the way its picture is.
    private func colourSettings(look: ClipLook?, path: String, set: @escaping (Bool, @escaping (inout ProjectClip) -> Void) -> Void) -> some View {
        ClipLookEditor(look: look ?? ClipLook(), path: path, parts: [.colour]) { record, body in
            set(record) { clip in
                var look = clip.look ?? ClipLook()
                body(&look)
                clip.look = look.isDefault ? nil : look
            }
        }
    }

    private func songHeader(_ song: ProjectMusic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(song.name, systemImage: "music.note").font(.callout.weight(.semibold)).lineLimit(2).padding(.horizontal, 8).padding(.bottom, 6)
            inspectorRow("Starts at") { Text(Format.duration(song.at)).monospacedDigit() }
            hint("Its volume and fades are in Audio.")
        }
    }

    /// Nothing chosen: the edit as a whole.
    private var overview: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(model.project.name).font(.callout.weight(.semibold)).lineLimit(2).padding(.horizontal, 8).padding(.bottom, 4)
            inspectorRow("Length") { Text(verbatim: Format.duration(model.duration)).monospacedDigit() }
            inspectorRow("Clips") { Text(verbatim: "\(model.project.clips.count)").monospacedDigit() }
            inspectorRow("Frame") {
                Text(verbatim: "\(Int(model.renderSize.width))×\(Int(model.renderSize.height)) · \(RawClipDetails.rate(model.frameRate)) fps").monospacedDigit()
            }
            let tracks = model.project.tracks ?? []
            if !tracks.isEmpty {
                inspectorRow("Tracks") {
                    Text(verbatim: [tracks.filter { $0.kind == .video }.count, tracks.filter { $0.kind == .audio }.count]
                        .enumerated().compactMap { $1 == 0 ? nil : ($0 == 0 ? String(localized: "\($1) over") : String(localized: "\($1) sound")) }
                        .joined(separator: " · "))
                }
            }
            if model.hasRange {
                inspectorRow("In to Out") {
                    Text(verbatim: "\(Format.duration(model.range.lowerBound))–\(Format.duration(model.range.upperBound))").monospacedDigit()
                    Button { model.clearRange() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).foregroundStyle(.secondary)
                        .help("Clear the in and out points (⌥X)")
                }
            }
            Text("Select a clip on the timeline to change it.")
                .font(.callout).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 8)
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
                    Button("Freeze Frame") { model.freezeFrame() }
                        .help("Holds the frame at the playhead for two seconds (⇧F)")
                    if clip.ownAudio == false {
                        Button("Attach Audio") { model.attachAudio([clip.id]) }
                    } else if clip.freeze == nil {
                        Button("Detach Audio") { model.detachAudio([clip.id]) }
                            .help("Its sound on a track of its own, to move, trim or fade apart from the picture")
                    }
                    Button("Open File") { StudioNavigator.shared.open(EditorTarget(path: clip.path), at: clip.start) }
                    Divider()
                    Button("Delete", role: .destructive) { model.delete([clip.id]) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            ClipLookEditor(look: clip.look ?? ClipLook(), path: clip.path, parts: [.picture]) { record, body in
                model.set(clip.id, record: record) { clip in
                    var look = clip.look ?? ClipLook()
                    body(&look)
                    look.reframed = nil   // placed by hand now
                    clip.look = look.isDefault ? nil : look
                }
            }
            if let index = model.project.clips.firstIndex(where: { $0.id == clip.id }), index + 1 < model.project.clips.count {
                let transition = model.transition(into: index + 1)
                FoldSection(title: "Transition", key: "clip-transition") {
                    inspectorRow("At the End") {
                        Picker("At the End", selection: Binding(get: { transition?.kind }, set: { kind in
                            model.setTransition(into: index + 1, kind.map { ProjectTransition(kind: $0, length: transition?.length ?? 1) })
                        })) {
                            Text("Cut").tag(ProjectTransition.Kind?.none)
                            ForEach(ProjectTransition.Group.allCases, id: \.self) { group in
                                Section(group.label) {
                                    ForEach(group.kinds, id: \.self) { kind in
                                        Text(ProjectTransition(kind: kind, length: 1).label).tag(ProjectTransition.Kind?.some(kind))
                                    }
                                }
                            }
                        }
                        .labelsHidden()
                    }
                    if let transition {
                        inspectorRow("Length") {
                            Slider(value: Binding(get: { transition.length }, set: { value in
                                model.setTransition(into: index + 1, ProjectTransition(kind: transition.kind, length: value), record: false)
                            }), in: 0.2...3) { editing in
                                if !editing { model.setTransition(into: index + 1, model.transition(into: index + 1)) }
                            }
                            Text(String(format: "%.1f s", transition.length)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(minWidth: 38, alignment: .trailing).fixedSize()
                        }
                    }
                }
            }
        }
    }

    private func itemSettings(_ item: ProjectClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.name).font(.callout.weight(.semibold)).lineLimit(2)
                    Text(verbatim: "\(item.file.lastPathComponent) · \(Format.duration(item.length))")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                Menu {
                    Button("Open File") { StudioNavigator.shared.open(EditorTarget(path: item.path), at: item.start) }
                    Divider()
                    Button("Delete", role: .destructive) { model.removeItems([item.id]) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            .padding(.horizontal, 8)
            .padding(.bottom, 4)
            if item.link != nil {
                Label("The sound of a clip, linked: it moves with it.", systemImage: "link")
                    .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
            }
            if Converting.isVideo(item.file), model.project.tracks?.first(where: { $0.items.contains { $0.id == item.id } })?.kind == .video {
                ClipLookEditor(look: item.look ?? ClipLook(), path: item.path, parts: [.picture]) { record, body in
                    model.setItem(item.id, record: record) { item in
                        var look = item.look ?? ClipLook()
                        body(&look)
                        item.look = look.isDefault ? nil : look
                    }
                }
            }
        }
    }

    private func clipAudio(_ clip: ProjectClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(clip.name, systemImage: "film").font(.callout.weight(.semibold)).lineLimit(2).padding(.horizontal, 8)
            FoldSection(title: "Volume and Fades", key: "clip-audio") {
                inspectorRow("Volume") {
                    Slider(value: Binding(get: { clip.volume }, set: { value in model.set(clip.id, record: false) { $0.volume = value } }), in: 0...2) { editing in
                        if !editing { model.set(clip.id) { _ in } }
                    }
                    Text(verbatim: "\(Int(clip.volume * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38, alignment: .trailing).fixedSize()
                }
                inspectorRow("Fade In") {
                    Slider(value: Binding(get: { clip.fadeIn }, set: { value in model.set(clip.id, record: false) { $0.fadeIn = value } }), in: 0...3) { editing in
                    if !editing { model.set(clip.id) { _ in } }
                }
                    Text(String(format: "%.1f s", clip.fadeIn)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38, alignment: .trailing).fixedSize()
                }
                inspectorRow("Fade Out") {
                    Slider(value: Binding(get: { clip.fadeOut }, set: { value in model.set(clip.id, record: false) { $0.fadeOut = value } }), in: 0...3) { editing in
                    if !editing { model.set(clip.id) { _ in } }
                }
                    Text(String(format: "%.1f s", clip.fadeOut)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38, alignment: .trailing).fixedSize()
                }
            }
        }
    }

    private func itemAudio(_ item: ProjectClip) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(item.name, systemImage: "waveform").font(.callout.weight(.semibold)).lineLimit(2).padding(.horizontal, 8)
            FoldSection(title: "Volume and Fades", key: "item-audio") {
                inspectorRow("Volume") {
                    Slider(value: Binding(get: { item.volume }, set: { value in model.setItem(item.id, record: false) { $0.volume = value } }), in: 0...2) { editing in
                        if !editing { model.setItem(item.id) { _ in } }
                    }
                    Text(verbatim: "\(Int(item.volume * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38, alignment: .trailing).fixedSize()
                }
                inspectorRow("Fade In") {
                    Slider(value: Binding(get: { item.fadeIn }, set: { value in model.setItem(item.id, record: false) { $0.fadeIn = value } }), in: 0...3) { editing in
                        if !editing { model.setItem(item.id) { _ in } }
                    }
                    Text(String(format: "%.1f s", item.fadeIn)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38, alignment: .trailing).fixedSize()
                }
                inspectorRow("Fade Out") {
                    Slider(value: Binding(get: { item.fadeOut }, set: { value in model.setItem(item.id, record: false) { $0.fadeOut = value } }), in: 0...3) { editing in
                        if !editing { model.setItem(item.id) { _ in } }
                    }
                    Text(String(format: "%.1f s", item.fadeOut)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38, alignment: .trailing).fixedSize()
                }
            }
        }
    }

    private func musicSettings(_ song: ProjectMusic) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(song.name, systemImage: "music.note").font(.callout.weight(.semibold)).lineLimit(2).padding(.horizontal, 8).padding(.bottom, 6)
            inspectorRow("Starts at") { Text(Format.duration(song.at)).monospacedDigit() }
            inspectorRow("Volume") {
                Slider(value: Binding(get: { song.volume }, set: { value in model.setMusic(song.id, record: false) { $0.volume = value } }), in: 0...1.5) { editing in
                    if !editing { model.setMusic(song.id) { _ in } }
                }
                Text(verbatim: "\(Int(song.volume * 100))%").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38, alignment: .trailing).fixedSize()
            }
            inspectorRow("Fade In") {
                Slider(value: Binding(get: { song.fadeIn }, set: { value in model.setMusic(song.id, record: false) { $0.fadeIn = value } }), in: 0...6) { editing in
                    if !editing { model.setMusic(song.id) { _ in } }
                }
            }
            inspectorRow("Fade Out") {
                Slider(value: Binding(get: { song.fadeOut }, set: { value in model.setMusic(song.id, record: false) { $0.fadeOut = value } }), in: 0...8) { editing in
                    if !editing { model.setMusic(song.id) { _ in } }
                }
            }
            HStack {
                Toggle("Lower under speech", isOn: Binding(get: { song.duck != nil }, set: { on in model.setMusic(song.id) { $0.duck = on ? -12 : nil } }))
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("The song drops while someone speaks in the clips, and comes back after")
                Spacer()
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(minHeight: 28)
            if let duck = song.duck {
                inspectorRow("Lower by") {
                    Slider(value: Binding(get: { duck }, set: { value in model.setMusic(song.id, record: false) { $0.duck = value.rounded() } }), in: -24 ... -6) { editing in
                        if !editing { model.setMusic(song.id) { _ in } }
                    }
                    Text(verbatim: "\(Int(duck)) dB").font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 38, alignment: .trailing).fixedSize()
                }
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

    private func lookSettings(_ look: ProjectAdjustment) -> some View {
        func slider(_ title: LocalizedStringKey, _ path: WritableKeyPath<ProjectAdjustment, Double>, _ range: ClosedRange<Double>,
                    _ format: String, scale: Double = 1, reset: Double = 0) -> some View {
            let value = look[keyPath: path]
            return inspectorRow(title) {
                Slider(value: Binding(get: { value }, set: { new in model.setAdjustment(look.id, record: false) { $0[keyPath: path] = new } }), in: range) { editing in
                    if !editing { model.setAdjustment(look.id, record: true) { _ in } }
                }
                Text(String(format: format, value * scale)).font(.caption.monospacedDigit()).foregroundStyle(value == reset ? .tertiary : .secondary)
                    .frame(minWidth: 46, alignment: .trailing)
                    .fixedSize()
                    .onTapGesture(count: 2) { model.setAdjustment(look.id, record: true) { $0[keyPath: path] = reset } }
                    .help("Double-click to reset")
            }
        }
        return VStack(alignment: .leading, spacing: 4) {
            Label("Look", systemImage: "camera.filters").font(.callout.weight(.semibold)).padding(.horizontal, 8).padding(.bottom, 6)
            inspectorRow("From") { Text(Format.duration(look.start)).monospacedDigit() }
            inspectorRow("To") { Text(Format.duration(look.end)).monospacedDigit() }
            slider("Amount", \.amount, 0...1, "%.0f%%", scale: 100, reset: 1)
            slider("Exposure", \.color.exposure, -3...3, "%+.2f")
            slider("Contrast", \.color.contrast, -100...100, "%+.0f")
            slider("Saturation", \.color.saturation, -100...100, "%+.0f")
            slider("Temperature", \.color.temperature, -100...100, "%+.0f")
            slider("Tint", \.color.tint, -100...100, "%+.0f")
            inspectorRow("LUT") {
                Text(look.color.lut.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent } ?? String(localized: "None"))
                    .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.allowedContentTypes = [UTType(filenameExtension: "cube")].compactMap { $0 }
                    guard panel.runModal() == .OK, let url = panel.url, LUTFile.read(url.path) != nil else { return }
                    model.setAdjustment(look.id, record: true) { $0.color.lut = url.path }
                }
                if look.color.lut != nil {
                    Button { model.setAdjustment(look.id, record: true) { $0.color.lut = nil } } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain)
                }
            }
            if look.color.lut != nil { slider("LUT Amount", \.color.lutAmount, 0...1, "%.2f", reset: 1) }
            HStack {
                Spacer()
                Button("Remove", role: .destructive) { model.removeAdjustment(look.id); model.selected = [] }
            }
            .controlSize(.small)
            .padding(.horizontal, 8)
            .padding(.top, 8)
        }
    }
}

// MARK: - Text and Local AI

/// The words of the edit: what's said (the transcript at the playhead), the subtitles, and the titles.
private struct ProjectTextTab: View {
    @Bindable var model: ProjectModel
    @AppStorage("projectTextPart") private var part = Part.transcript

    enum Part: String, CaseIterable, Identifiable {
        case transcript, subtitles, titles
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .transcript: "Transcript"
            case .subtitles: "Subtitles"
            case .titles: "Titles"
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Text", selection: $part) { ForEach(Part.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 14)
            switch part {
            case .transcript: ProjectFocusedFile(model: model, ai: false)
            case .subtitles: ProjectSubtitlesPanel(model: model)
            case .titles: ProjectTitlesPanel(model: model)
            }
        }
    }
}

/// Local AI on the file at the playhead, and the story across every clip.
private struct ProjectAITab: View {
    @Bindable var model: ProjectModel
    @AppStorage("projectAIPart") private var part = Part.tools

    enum Part: String, CaseIterable, Identifiable {
        case tools, story
        var id: String { rawValue }
        var title: LocalizedStringKey {
            switch self {
            case .tools: "This Clip"
            case .story: "Story"
            }
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            Picker("Local AI", selection: $part) { ForEach(Part.allCases) { Text($0.title).tag($0) } }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .padding(.horizontal, 14)
            switch part {
            case .tools: ProjectFocusedFile(model: model, ai: true)
            case .story: ProjectStoryPanel(model: model)
            }
        }
    }
}

/// The Editor's transcript or local-AI tools, on the file at the playhead (or the clip chosen),
/// in its own time.
private struct ProjectFocusedFile: View {
    @Bindable var model: ProjectModel
    /// The local-AI tools; else the transcript.
    let ai: Bool

    var body: some View {
        if let path = model.focusedPath {
            EditorAIPanel(model: model.focus(path), part: ai ? .ai : .transcript)
                .id(path)
        } else {
            Text("Add a clip to the timeline.").foregroundStyle(.secondary).padding(14)
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
            .panelColumn()
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

    /// A title from the Titles library, chosen on the timeline.
    private var motionItem: ProjectClip? {
        guard model.selected.count == 1, let id = model.selected.first else { return nil }
        return (model.project.tracks ?? []).flatMap(\.items).first { $0.id == id && $0.motion != nil }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let item = motionItem, let motion = item.motion { MotionTitleEditor(model: model, item: item, motion: motion) }
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
            .panelColumn()
            .padding(.bottom, 12)
        }
    }
}

/// A template title's words, colours and plate, changed live in the viewer (and its export).
private struct MotionTitleEditor: View {
    @Bindable var model: ProjectModel
    let item: ProjectClip
    let motion: ProjectMotion

    var body: some View {
        SidebarSection(title: Text(item.name)) {
            ForEach(motion.motionTemplate?.fields ?? []) { field in
                inspectorRow(LocalizedStringKey(field.label)) {
                    TextField(field.label, text: Binding(get: { motion.placement.texts[field.key] ?? "" },
                                                         set: { value in model.setMotion(item.id, record: false) { $0.placement.texts[field.key] = value } }),
                              prompt: Text(verbatim: field.placeholder), axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(1...3)
                        .labelsHidden()
                        .onSubmit { model.setMotion(item.id, record: true) { _ in } }
                }
            }
            inspectorRow("Text") { well(\.text) }
            inspectorRow("Accent") {
                well(\.accent)
                well(\.accent2).help("The accent's partner: gradients run from one to the other")
            }
            inspectorRow("Background") {
                if motion.style.plates != false {
                    well(\.secondary).help("The plates behind the words")
                    if motion.style.background != nil, motion.motionTemplate?.fullFrame == true {
                        ColorPicker("Background", selection: colour(Binding(get: { motion.style.background ?? .ink },
                                                                            set: { value in model.setMotion(item.id, record: false) { $0.style.background = value } })),
                                    supportsOpacity: false)
                            .labelsHidden()
                    }
                }
                Toggle("Background", isOn: Binding(get: { motion.style.plates != false },
                                                   set: { on in model.setMotion(item.id, record: true) { $0.style.plates = on ? nil : false } }))
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .help("Off: just the words, see-through behind them")
            }
        }
    }

    private func well(_ path: WritableKeyPath<MotionStyle, MotionColor>) -> some View {
        ColorPicker("", selection: colour(Binding(get: { motion.style[keyPath: path] },
                                                 set: { value in model.setMotion(item.id, record: false) { $0.style[keyPath: path] = value } })),
                    supportsOpacity: false)
            .labelsHidden()
    }

    private func colour(_ color: Binding<MotionColor>) -> Binding<Color> {
        Binding(get: { Color(cgColor: color.wrappedValue.cg) },
                set: { new in if let cg = NSColor(new).usingColorSpace(.sRGB)?.cgColor { color.wrappedValue = MotionColor(cg) } })
    }
}

// MARK: - Export

private struct ProjectExportPanel: View {
    @Bindable var model: ProjectModel
    @Environment(DownloadManager.self) private var manager
    @AppStorage("projectExportAudio") private var audioOnly = false
    @AppStorage("editorRenderSettings") private var stored = ""
    /// The whole edit, only the in to the out point, or each clip as a file of its own.
    @AppStorage("projectExportPart") private var part = Part.whole

    enum Part: String { case whole, range, each }

    /// What's exported now (the in to the out point only with a range).
    private var shown: Part { part == .range && !model.hasRange ? .whole : part }

    private var exporting: Project {
        shown == .whole ? model.project : model.project.cut(to: model.range)
    }

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
                Picker("Part", selection: Binding(get: { shown }, set: { part = $0 })) {
                    Text("Whole Edit").tag(Part.whole)
                    if model.hasRange { Text("In to Out").tag(Part.range) }
                    Text("Each Clip").tag(Part.each)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .padding(.horizontal, 8)
                .help("The whole edit, only from the in to the out point (I and O), or each clip as a file of its own")
                RenderSettingsForm(audioOnly: audioOnly)
                VStack(alignment: .leading, spacing: 8) {
                    let settings = EditorRenderSettings(saved: stored)
                    let size = settings.outputSize(source: model.renderSize)
                    let length = exporting.duration
                    Text(verbatim: "\(Format.duration(length)) · \(Int(size.width))×\(Int(size.height)) · ≈ "
                         + ByteCountFormatter.string(fromByteCount: settings.estimatedBytes(source: model.renderSize, sourceFPS: model.frameRate,
                                                                                             length: length), countStyle: .file))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button {
                        if shown == .each {
                            model.exports.runEach(model.project, range: model.hasRange ? model.range : nil, settings: settings, audioOnly: audioOnly,
                                                  size: model.renderSize, fps: model.frameRate, lengths: model.knownLengths, manager: manager)
                        } else {
                            model.exports.enqueue(ExportJob(model, project: exporting, settings: settings, audioOnly: audioOnly), manager: manager)
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle())
                    .disabled(model.project.clips.isEmpty || (shown == .each && model.exports.isRunning))
                    if let progress = model.exports.progress {
                        ExportProgress(value: progress) { model.exports.stopAll() }
                    } else if let problem = model.exports.problem {
                        ProblemLabel(text: problem)
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
            .panelColumn()
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
            .panelColumn()
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
            Text(Format.duration(line.start)).font(.caption.monospacedDigit()).foregroundStyle(.secondary).frame(minWidth: 34, alignment: .leading).fixedSize()
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

extension ProjectModel {
    /// What's chosen on the timeline, for the inspector to follow (one thing; several stay put).
    var chosen: ProjectInspector.Tab.Chosen {
        if selected.isEmpty { return selectedTitle == nil ? .nothing : .title }
        guard selected.count == 1, let id = selected.first else { return .nothing }
        if adjustment(id) != nil { return .look }
        if let (t, i) = trackItem(id) { return project.tracks![t].items[i].motion != nil ? .title : .clip }
        return project.clips.contains { $0.id == id } ? .clip : .nothing
    }
}
