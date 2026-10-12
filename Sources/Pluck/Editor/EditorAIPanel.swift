#if STUDIO
import SwiftUI

/// Local AI in the Editor's sidebar. The Transcript tab: what's said, to read along, jump with and
/// set the range by. The Local AI tab: the best moments and filler words, found and marked on the
/// timeline (filler words cut out in one go), and Pluck's AI tools for this file.
struct EditorAIPanel: View {
    enum Part { case transcript, ai, subtitles }

    @Bindable var model: EditorModel
    let part: Part
    @Environment(AIStudio.self) private var ai
    @Environment(DownloadManager.self) private var manager
    @State private var transcript: Transcript?
    @State private var cues: [Transcript.Cue] = []
    @State private var search = ""
    @State private var anchor: Transcript.Cue?
    @State private var item: DownloadItem?
    @State private var finding = false
    @State private var problem: String?
    /// The sentence the transcript list is scrolled to.
    @State private var scrolledCue: Double?
    /// A tool's window open over the Editor.
    @State private var open: EditorToolSheet?
    /// The subtitle the list is scrolled to.
    @State private var scrolledSubtitle: UUID?
    /// Subtitles were asked for before there was a transcript: made once it's there.
    @State private var makeSubtitlesWhenTranscribed = false

    var body: some View {
        Group {
            switch part {
            case .transcript: transcriptTab
            case .ai: aiTab
            case .subtitles: subtitlesTab
            }
        }
        .task {
            load()
            // Screenshots: -PluckScreenshotFind YES finds the best moments and filler words straight away.
            if part == .subtitles, ScreenshotMode.scene == "editor", UserDefaults.standard.bool(forKey: "PluckScreenshotSubtitles"),
               transcript != nil, model.subtitles.isEmpty {
                makeSubtitles()
            }
            if part == .ai, ScreenshotMode.scene == "editor", UserDefaults.standard.bool(forKey: "PluckScreenshotFind"), transcript != nil {
                findMoments()
                findFillers()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: TranscriptStore.didSave)) { _ in load() }
        .sheet(item: $open) { EditorToolSheetContent(sheet: $0) }
    }

    private func load() {
        guard let found = TranscriptStore.find(forFile: model.file.path) else { return }
        transcript = found
        if makeSubtitlesWhenTranscribed, model.subtitles.isEmpty {
            makeSubtitlesWhenTranscribed = false
            makeSubtitles()
        }
        cues = found.cues(maxCharacters: 90, maxDuration: 6)
        // Chapters local AI made, when the file has none of its own.
        if let chapters = found.chapters, !chapters.isEmpty, !model.markers.contains(where: { $0.kind == .chapter }) {
            model.replaceMarkers(.chapter, with: chapters.map { EditorMarker(kind: .chapter, start: $0.start, title: $0.title) })
        }
    }

    /// This file as an item in Pluck's list, which the AI tools work on.
    private func fileItem() -> DownloadItem? {
        if let item { return item }
        let found = manager.items.first { $0.existingFile?.path == model.file.path } ?? manager.addLocalFiles([model.file]).first
        item = found
        return found
    }

    // MARK: - Transcript

    private var shownCues: [Transcript.Cue] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return cues }
        return cues.filter { $0.text.localizedStandardContains(query) }
    }

    private var current: Transcript.Cue? { cues.last { $0.start <= model.time + 0.05 } }

    @ViewBuilder private var transcriptTab: some View {
        if transcript == nil {
            VStack(alignment: .leading, spacing: 10) {
                if let status = item?.aiStatus {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text(status).foregroundStyle(.secondary)
                    }
                } else if LocalAI.canTranscribe {
                    Text("Writes down what’s said, on this Mac, so you can cut by the words.").foregroundStyle(.secondary)
                    Button("Transcribe", systemImage: "waveform") {
                        if let item = fileItem() { ai.transcribeInBackground([item]) }
                    }
                    .buttonStyle(GlassCapsuleButtonStyle())
                } else {
                    Text("Transcripts need macOS 26 and Apple Intelligence.").foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary).accessibilityHidden(true)
                    TextField("Find what was said", text: $search).textFieldStyle(.plain)
                }
                .font(.callout)
                .padding(.horizontal, 8)
                .frame(height: 26)
                .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(.fill.tertiary))
                .padding(.horizontal, 8)
                .padding(.bottom, 6)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(shownCues) { cue in cueRow(cue) }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 6)
                }
                .scrollPosition(id: $scrolledCue, anchor: .center)
                .onChange(of: current?.id) { _, id in
                    if model.isPlaying, search.isEmpty, let id { withAnimation { scrolledCue = id } }
                }
                Text("Click to go there. ⇧-click another line to make the range.")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .padding(8)
            }
        }
    }

    private func cueRow(_ cue: Transcript.Cue) -> some View {
        let inRange = model.hasRange && cue.start >= model.rangeStart - 0.05 && cue.end <= model.rangeEnd + 0.05
        let playing = current?.id == cue.id
        let removed = model.part(at: cue.start + 0.01)?.removed ?? false
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(Format.duration(cue.start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary).frame(width: 32, alignment: .leading)
            Text(cue.text).font(.callout)
                .foregroundStyle(playing ? .primary : .secondary)
                .strikethrough(removed, color: .red)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small)
            .fill(inRange ? Color.yellow.opacity(0.16) : playing ? Color.accentColor.opacity(0.14) : .clear))
        .contentShape(.rect)
        .onTapGesture {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true, let anchor {
                model.inPoint = model.snappedToFrame(min(anchor.start, cue.start))
                model.outPoint = model.snappedToFrame(max(anchor.end, cue.end))
                model.seek(to: model.rangeStart)
            } else {
                anchor = cue
                model.seek(to: cue.start)
            }
        }
    }

    // MARK: - Subtitles

    @ViewBuilder private var subtitlesTab: some View {
        if model.subtitles.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text("Subtitles from the transcript, to edit here: the words, the size and where they sit. They’re burned into the export.")
                    .foregroundStyle(.secondary)
                if transcript != nil {
                    Button("Make from the Transcript", systemImage: "captions.bubble") { makeSubtitles() }
                        .buttonStyle(GlassCapsuleButtonStyle())
                } else {
                    Text("Needs the transcript first.").font(.caption).foregroundStyle(.secondary)
                }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(spacing: 0) {
                subtitleStyleControls
                Divider().padding(.vertical, 6)
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach($model.subtitles) { $cue in subtitleRow($cue) }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, 6)
                }
                .scrollPosition(id: $scrolledSubtitle, anchor: .center)
                .onChange(of: model.subtitle(at: model.time)?.id) { _, id in
                    if model.isPlaying, let id { withAnimation { scrolledSubtitle = id } }
                }
                HStack {
                    Text("\(model.subtitles.count) lines").font(.caption2).foregroundStyle(.tertiary)
                    Spacer()
                    Button("Start Over") { makeSubtitles() }
                        .buttonStyle(.link)
                        .font(.caption)
                        .help("Make them again from the transcript (your changes are lost)")
                        .disabled(transcript == nil)
                }
                .padding(8)
            }
        }
    }

    private var subtitleStyleControls: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle("Show", isOn: $model.showSubtitles)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("Show them on the picture and burn them into the export")
                Spacer()
                Toggle("Box", isOn: $model.subtitleStyle.box)
                    .toggleStyle(.switch)
                    .controlSize(.mini)
                    .help("On a dark box, or with an outline")
            }
            HStack(spacing: 6) {
                Image(systemName: "textformat.size.smaller").foregroundStyle(.secondary).accessibilityHidden(true)
                Slider(value: $model.subtitleStyle.scale, in: 0.5...2)
                    .controlSize(.mini)
                    .accessibilityLabel(Text("Size"))
                Image(systemName: "textformat.size.larger").foregroundStyle(.secondary).accessibilityHidden(true)
            }
            HStack(spacing: 6) {
                ForEach(SubtitleStyle.swatches, id: \.self) { hex in
                    let style = SubtitleStyle(color: hex)
                    Button { model.subtitleStyle.color = hex } label: {
                        Circle().fill(style.swiftUIColor)
                            .overlay(Circle().strokeBorder(.separator))
                            .overlay(Circle().strokeBorder(Color.accentColor, lineWidth: 2).padding(-3).opacity(model.subtitleStyle.color == hex ? 1 : 0))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hex)
                }
                Spacer()
                Button("Bottom") { model.subtitleStyle.x = 0.5; model.subtitleStyle.y = 0.88 }
                    .buttonStyle(.link)
                    .font(.caption)
                    .help("Back to the bottom middle. Or drag them on the picture.")
            }
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .onChange(of: model.subtitleStyle) { model.saveSubtitles() }
        .onChange(of: model.showSubtitles) { model.saveSubtitles() }
    }

    private func subtitleRow(_ cue: Binding<SubtitleCue>) -> some View {
        let playing = model.subtitle(at: model.time)?.id == cue.wrappedValue.id
        return HStack(alignment: .top, spacing: 6) {
            Button { model.seek(to: cue.wrappedValue.start + 0.01) } label: {
                Text(Format.duration(cue.wrappedValue.start)).font(.caption2.monospacedDigit()).foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .frame(width: 32, alignment: .leading)
            .padding(.top, 2)
            .help("Go there")
            TextField("", text: cue.text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.callout)
                .lineLimit(1...4)
                .onSubmit { model.saveSubtitles() }
                .onChange(of: cue.wrappedValue.text) { model.saveSubtitles() }
            Button { model.subtitles.removeAll { $0.id == cue.wrappedValue.id }; model.saveSubtitles() } label: {
                Image(systemName: "minus.circle").foregroundStyle(.tertiary)
            }
            .buttonStyle(.plain)
            .help("Delete this line")
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: Design.Radius.small).fill(playing ? Color.accentColor.opacity(0.14) : .clear))
        .id(cue.wrappedValue.id)
    }

    private func makeSubtitles() {
        guard let transcript else { return }
        model.subtitles = transcript.cues(maxCharacters: 84, maxDuration: 6).map {
            SubtitleCue(start: $0.start, end: $0.end, text: Transcript.twoLines($0.text))
        }
        model.showSubtitles = true
        model.saveSubtitles()
    }

    // MARK: - Local AI

    private var aiTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SidebarSection(title: Text("Find")) {
                    let moments = model.markers.filter { $0.kind == .moment }
                    let fillers = model.markers.filter { $0.kind == .filler }
                    SidebarRow(symbol: "star", title: Text("Best Moments"), detail: moments.isEmpty ? nil : Text(verbatim: "\(moments.count)")) {
                        Button(moments.isEmpty ? "Find" : "Again") { findMoments() }
                            .buttonStyle(.link)
                            .help("The strongest moments for a short, chosen from what’s said")
                    }
                    SidebarRow(symbol: "text.badge.minus", title: Text("Filler Words"), detail: fillers.isEmpty ? nil : Text(verbatim: "\(fillers.count)")) {
                        if fillers.isEmpty {
                            Button("Find") { findFillers() }
                                .buttonStyle(.link)
                                .help("Every “um”, “uh” and “like”")
                        } else {
                            Button("Cut All") { model.cutOut(fillers.compactMap(\.span)) }
                                .buttonStyle(.link)
                                .help("Cut every filler word out of the edit (⌘Z undoes it)")
                        }
                    }
                    if finding {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("Finding the best moments…")
                        }
                        .font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    if transcript == nil {
                        Text("Needs the transcript first.").font(.caption).foregroundStyle(.secondary).padding(.horizontal, 8)
                    }
                    if let problem {
                        Text(problem).font(.caption).foregroundStyle(.orange).padding(.horizontal, 8)
                    }
                    ForEach(moments) { moment in
                        SidebarRow(symbol: "star.fill", title: Text(moment.title), detail: Text(Format.duration(moment.start))) { EmptyView() }
                            .onTapGesture { model.select(moment) }
                            .help("Make this the range")
                            .padding(.leading, 14)
                    }
                }
                .disabled(transcript == nil || finding)

                if let status = item?.aiStatus {
                    SidebarSection(title: Text("Working")) {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(status).font(.callout)
                            if let progress = item?.aiProgress {
                                ProgressView(value: progress)
                            } else {
                                ProgressView().progressViewStyle(.linear)
                            }
                            Text("The result is saved next to the original.").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .padding(.horizontal, 8)
                    }
                }
                SidebarSection(title: Text("Tools")) {
                    ForEach(Tool.allCases.filter(available), id: \.self) { tool in
                        SidebarRow(symbol: symbol(tool), title: Text(title(tool))) {
                            Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
                        }
                        .onTapGesture { run(tool) }
                        .opacity(enabled(tool) ? 1 : 0.4)
                        .allowsHitTesting(enabled(tool))
                    }
                    Text("Subtitles and cutting pauses happen in the edit. The other tools save a new file next to the original, on this Mac.")
                        .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 8).padding(.top, 4)
                }
            }
            .padding(.horizontal, 6)
            .padding(.bottom, 12)
        }
    }

    private func findMoments() {
        guard let transcript else { return }
        finding = true
        problem = nil
        Task {
            var options = Shorts.Options()
            options.count = 6
            let moments = await Shorts.moments(in: transcript, options: options)
            model.replaceMarkers(.moment, with: moments.map { EditorMarker(kind: .moment, start: $0.start, end: $0.end, title: $0.title) })
            if moments.isEmpty { problem = String(localized: "No moments found: there’s too little speech in this file.") }
            finding = false
        }
    }

    private func findFillers() {
        guard let transcript else { return }
        let cuts = Tighten.fillerCuts(transcript.words, language: Locale(identifier: transcript.language))
        model.replaceMarkers(.filler, with: cuts.map { EditorMarker(kind: .filler, start: $0.lowerBound, end: $0.upperBound, title: String(localized: "Filler")) })
        problem = cuts.isEmpty ? String(localized: "No filler words found.") : nil
    }

    // MARK: - Tools

    fileprivate enum Tool: CaseIterable {
        case shorts, subtitles, tighten, enhance, background, blur, cleanup, stems
    }

    private func available(_ tool: Tool) -> Bool {
        switch tool {
        case .shorts, .subtitles: LocalAI.canTranscribe
        case .enhance: Enhance.isSupported
        case .cleanup: AudioCleanup.isSupported
        case .stems: Stems.isSupported
        case .tighten, .background, .blur: true
        }
    }

    private func enabled(_ tool: Tool) -> Bool {
        model.hasVideo || ![.shorts, .enhance, .background, .blur].contains(tool)
    }

    private func title(_ tool: Tool) -> LocalizedStringKey {
        switch tool {
        case .shorts: "Make Shorts…"
        case .subtitles: "Subtitles"
        case .tighten: "Cut Pauses & Fillers"
        case .enhance: "Upscale & Smooth…"
        case .background: "New Background…"
        case .blur: "Privacy Blur…"
        case .cleanup: "Clean Up Audio…"
        case .stems: "Separate Stems"
        }
    }

    private func symbol(_ tool: Tool) -> String {
        switch tool {
        case .shorts: "rectangle.portrait.on.rectangle.portrait.angled"
        case .subtitles: "captions.bubble"
        case .tighten: "scissors"
        case .enhance: "sparkles.tv"
        case .background: "person.and.background.dotted"
        case .blur: "eye.slash"
        case .cleanup: "waveform"
        case .stems: "slider.vertical.3"
        }
    }

    /// Subtitles and taking out pauses happen right here in the Editor; the other tools open
    /// their window over the Editor (not the main window) and show their progress here.
    private func run(_ tool: Tool) {
        switch tool {
        case .subtitles:
            UserDefaults.standard.set(EditorSidebar.Tab.subtitles.rawValue, forKey: "editorSidebarTab")
            if transcript != nil {
                if model.subtitles.isEmpty { makeSubtitles() }
            } else if let item = fileItem() {
                makeSubtitlesWhenTranscribed = true
                ai.transcribeInBackground([item])
            }
            return
        case .tighten:
            var spans = model.markers.filter { $0.kind == .silence }.compactMap(\.span)
            if let transcript {
                spans += Tighten.fillerCuts(transcript.words, language: Locale(identifier: transcript.language))
            }
            if spans.isEmpty {
                problem = String(localized: "No pauses or filler words to take out.")
            } else {
                model.cutOut(spans.sorted { $0.lowerBound < $1.lowerBound })
            }
            return
        default:
            break
        }
        guard let item = fileItem() else { return }
        if tool == .stems { ai.separateStems(item); return }
        open = EditorToolSheet(tool: tool, item: item)
    }
}

/// A local-AI tool's window, shown over the Editor.
private struct EditorToolSheet: Identifiable {
    let tool: EditorAIPanel.Tool
    let item: DownloadItem
    var id: String { "\(tool)" }
}

/// Presents a tool's window over the Editor, with what it needs.
private struct EditorToolSheetContent: View {
    let sheet: EditorToolSheet
    @Environment(AIStudio.self) private var ai

    var body: some View {
        switch sheet.tool {
        case .shorts: ShortsSheet(item: sheet.item).environment(ai)
        case .subtitles:
            if #available(macOS 26, *) { SubtitleSheet(items: [sheet.item]).environment(ai) }
        case .tighten: TightenSheet(items: [sheet.item]).environment(ai)
        case .enhance: EnhanceSheet(item: sheet.item).environment(ai)
        case .background: BackgroundSheet(item: sheet.item).environment(ai)
        case .blur: PrivacyBlurSheet(item: sheet.item).environment(ai)
        case .cleanup: AudioCleanupSheet(items: [sheet.item]).environment(ai)
        case .stems: EmptyView()
        }
    }
}
#endif
